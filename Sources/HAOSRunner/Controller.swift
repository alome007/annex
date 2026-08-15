import Foundation
import Virtualization
import os

@MainActor
final class Controller: NSObject, ObservableObject {
    static let shared = Controller()

    @Published private(set) var state: VMState = .ready
    @Published private(set) var stageStartedAt = Date()
    @Published private(set) var bootStartedAt: Date?
    @Published private(set) var freshInstall = false
    @Published private(set) var offerBootRepair = false
    @Published var settings = VMSettings.load() {
        didSet { settings.save() }
    }

    private let console = SerialConsole.shared
    private let shell: GuestShell
    private let log = Logger(subsystem: "casa.astrohome.haosrunner", category: "controller")
    private var machine: VZVirtualMachine?
    private var pipeline: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var progressPoll: Task<Void, Never>?
    private var silenceWatch: Task<Void, Never>?
    private var vmStateObservation: NSKeyValueObservation?
    private var quitCompletion: (() -> Void)?

    private override init() {
        shell = GuestShell(console: console)
        super.init()
        console.onLine = { [weak self] line in self?.handleConsoleLine(line) }
        console.onTail = { [weak self] tail in self?.shell.handleTail(tail) }
        if settings.startOnLaunch {
            Task { @MainActor in self.start() }
        }
    }

    var machineIsActive: Bool { machine != nil }
    var canErase: Bool { machine == nil && DiskBuilder.hasSource }

    func noteSettingsChanged() {
        objectWillChange.send()
    }

    // MARK: - Lifecycle

    func start() {
        guard machine == nil, !state.isBusy else { return }
        offerBootRepair = false
        console.clear()
        try? Paths.ensureSupportDirectory()
        console.beginFileLog(at: Paths.support.appending(path: "console.log"))
        shell.reset()
        bootStartedAt = .now
        pipeline = Task { await runPipeline() }
    }

    func stop() {
        guard let vm = machine, vm.canRequestStop else {
            forceStop()
            return
        }
        cancelBootWork()
        transition(.stopping, timeout: 120)
        do {
            try vm.requestStop()
        } catch {
            fail("Home Assistant did not accept the shutdown request: \(error.localizedDescription)")
        }
    }

    func forceStop() {
        cancelBootWork()
        guard let vm = machine else {
            transition(.stopped)
            return
        }
        transition(.stopping, timeout: 60)
        if vm.canStop {
            vm.stop { [weak self] _ in
                Task { @MainActor in self?.machineDidStop(error: nil) }
            }
        } else {
            machineDidStop(error: nil)
        }
    }

    func shutdownForQuit(completion: @escaping () -> Void) {
        guard let vm = machine else {
            completion()
            return
        }
        quitCompletion = completion
        if case .running = state {
            cancelBootWork()
            transition(.stopping)
            Task { [weak self] in
                guard let self else { return }
                if await self.suspendForQuit(vm) {
                    self.machine = nil
                    self.console.detach()
                    self.finishQuit()
                } else {
                    self.stop()
                }
            }
        } else {
            stop()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.quitCompletion != nil else { return }
            self.forceStop()
            try? await Task.sleep(for: .seconds(5))
            self.finishQuit()
        }
    }

    func eraseAndReinstall() {
        guard machine == nil else { return }
        SavedSession.discard()
        console.clear()
        pipeline = Task {
            transition(.starting(.preparingDisk), timeout: 600)
            do {
                try await DiskBuilder.rebuild()
                transition(.ready)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Boot pipeline

    private func runPipeline() async {
        do {
            freshInstall = !Paths.hasWorkingDisk
            if !Paths.hasWorkingDisk {
                if !DiskBuilder.hasSource {
                    transition(.starting(.downloadingImage(percent: nil)), timeout: 3600)
                    _ = try await ImageDownloader.downloadLatest { [weak self] percent in
                        Task { @MainActor in self?.updateImageDownloadPercent(percent) }
                    }
                }
                transition(.starting(.preparingDisk), timeout: 600)
                try await DiskBuilder.rebuild()
            }

            transition(.starting(.startingMachine), timeout: 60)
            let resumed = await resumeSavedSession()
            if !resumed {
                try await bootMachine()
            }
            shell.begin()
            startSilenceWatch()

            transition(.starting(.waitingForNetwork), timeout: 240)
            let ip = try await awaitGuestIP()
            log.notice("guest reachable at \(ip, privacy: .public)")

            transition(.starting(.waitingForHomeAssistant(downloadPercent: nil)), timeout: 2400)
            startProgressPolling()
            try await awaitProbe { await HTTPProbe.coreAnswers(ip: ip) }
            stopProgressPolling()

            transition(.starting(.connectingBridge), timeout: 300)
            if await !HTTPProbe.relayAnswers(ip: ip) {
                shell.run(RelayInstall.command)
                try await awaitProbe { await HTTPProbe.relayAnswers(ip: ip) }
            }

            guard let url = URL(string: "http://\(ip):\(RelayInstall.port)/") else {
                throw PipelineFailure(message: "The guest address \(ip) is not a valid URL host.")
            }
            transition(.running(url: url))
            log.notice("running at \(url.absoluteString, privacy: .public)")
        } catch is CancellationError {
        } catch let failure as PipelineFailure {
            fail(failure.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func resumeSavedSession() async -> Bool {
        guard SavedSession.exists else { return false }
        defer { SavedSession.discard() }
        guard SavedSession.matches(settings) else {
            log.notice("saved session discarded: settings changed")
            return false
        }
        do {
            let configuration = try VMBuilder.makeConfiguration(settings)
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            machine = vm
            observeVMState(vm)
            try await vm.restoreMachineStateFrom(url: Paths.savedState)
            try await vm.resume()
            log.notice("resumed saved session")
            return true
        } catch {
            log.error("resume failed, cold booting: \(error.localizedDescription, privacy: .public)")
            machine = nil
            return false
        }
    }

    private func suspendForQuit(_ vm: VZVirtualMachine) async -> Bool {
        guard vm.canPause else { return false }
        do {
            try Paths.ensureSupportDirectory()
            try await vm.pause()
            try await vm.saveMachineStateTo(url: Paths.savedState)
            SavedSession.record(settings)
            log.notice("session suspended")
            return true
        } catch {
            log.error("suspend failed: \(error.localizedDescription, privacy: .public)")
            SavedSession.discard()
            return false
        }
    }

    private func bootMachine() async throws {
        let configuration: VZVirtualMachineConfiguration
        do {
            configuration = try VMBuilder.makeConfiguration(settings)
        } catch {
            throw PipelineFailure(message: error.localizedDescription)
        }
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        machine = vm
        observeVMState(vm)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vm.start { continuation.resume(with: $0) }
            }
        } catch {
            machine = nil
            throw PipelineFailure(message: "The machine could not start: \(error.localizedDescription)")
        }
    }

    private func awaitGuestIP() async throws -> String {
        guard let mac = StableMAC.current else {
            throw PipelineFailure(message: "The machine has no stored network identity. Start it again.")
        }
        while true {
            try Task.checkCancellation()
            if let ip = await GuestAddressResolver.resolve(mac: mac) { return ip }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func awaitProbe(_ probe: () async -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            if await probe() { return }
            try await Task.sleep(for: .seconds(1.5))
        }
    }

    // MARK: - Progress

    private func startProgressPolling() {
        progressPoll?.cancel()
        progressPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                guard case .starting(.waitingForHomeAssistant) = self.state, self.shell.isAtShell else { continue }
                self.console.send(RelayInstall.supervisorProgressCommand)
            }
        }
    }

    private func stopProgressPolling() {
        progressPoll?.cancel()
        progressPoll = nil
    }

    private func updateImageDownloadPercent(_ percent: Int) {
        guard case .starting(.downloadingImage(let current)) = state, percent != current else { return }
        transition(.starting(.downloadingImage(percent: percent)), timeout: 3600)
    }

    private func handleConsoleLine(_ line: String) {
        shell.handleLine(line)
        guard case .starting(.waitingForHomeAssistant(let current)) = state,
              let percent = SupervisorLog.downloadPercent(in: line),
              percent != current else { return }
        transition(.starting(.waitingForHomeAssistant(downloadPercent: percent)), timeout: 2400)
    }

    // MARK: - State

    private func transition(_ new: VMState, timeout: TimeInterval? = nil) {
        watchdog?.cancel()
        watchdog = nil
        if state.phase != new.phase { stageStartedAt = .now }
        state = new
        log.notice("state \(new.phase, privacy: .public)")
        guard let timeout else { return }
        let phase = new.phase
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.stageTimedOut(phase: phase, after: timeout)
        }
    }

    private func stageTimedOut(phase: String, after seconds: TimeInterval) {
        guard state.phase == phase else { return }
        pipeline?.cancel()
        stopProgressPolling()
        let minutes = Int(seconds / 60)
        switch state {
        case .starting(let stage):
            fail("\(stage.title) has not finished after \(minutes) minutes. The console below may show why. Force stop powers the machine off.")
        case .stopping:
            fail("The machine has not shut down after \(minutes) minutes. Force stop powers it off.")
        default:
            fail("Timed out after \(minutes) minutes.")
        }
    }

    private func fail(_ message: String) {
        stopProgressPolling()
        log.error("failed: \(message, privacy: .public)")
        transition(.failed(message))
    }

    private func startSilenceWatch() {
        silenceWatch?.cancel()
        silenceWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self else { return }
            guard case .starting = self.state, self.console.lastGuestOutputAt == nil else { return }
            self.forceStop()
            self.offerBootRepair = true
            self.fail(
                "The machine started but produced no boot output for 90 seconds. "
                    + "This usually means its boot selector ran out of retries after interrupted starts. "
                    + "Repair startup resets it and tries again — your Home Assistant data is untouched."
            )
        }
    }

    func repairAndRestart() {
        guard machine == nil else { return }
        offerBootRepair = false
        pipeline = Task {
            transition(.starting(.preparingDisk), timeout: 120)
            do {
                try await BootRepair.resetBootSlots(diskImage: Paths.diskImage)
                log.notice("boot slots reset")
                transition(.ready)
                start()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func cancelBootWork() {
        pipeline?.cancel()
        pipeline = nil
        silenceWatch?.cancel()
        silenceWatch = nil
        stopProgressPolling()
        shell.reset()
    }

    private func observeVMState(_ vm: VZVirtualMachine) {
        vmStateObservation = vm.observe(\.state, options: [.initial, .new]) { [log] machine, _ in
            let name: String = switch machine.state {
            case .stopped: "stopped"
            case .running: "running"
            case .paused: "paused"
            case .error: "error"
            case .starting: "starting"
            case .pausing: "pausing"
            case .resuming: "resuming"
            case .stopping: "stopping"
            case .saving: "saving"
            case .restoring: "restoring"
            @unknown default: "unknown(\(machine.state.rawValue))"
            }
            log.notice("vz state \(name, privacy: .public)")
        }
    }

    private func machineDidStop(error: Error?) {
        cancelBootWork()
        watchdog?.cancel()
        watchdog = nil
        vmStateObservation = nil
        console.detach()
        machine = nil
        bootStartedAt = nil
        if let error {
            fail(error.localizedDescription)
        } else if case .failed = state {
        } else {
            transition(.stopped)
        }
        finishQuit()
    }

    private func finishQuit() {
        guard let completion = quitCompletion else { return }
        quitCompletion = nil
        completion()
    }
}

extension Controller: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ vm: VZVirtualMachine) {
        Task { @MainActor in self.machineDidStop(error: nil) }
    }

    nonisolated func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in self.machineDidStop(error: error) }
    }
}
