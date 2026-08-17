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
    @Published private(set) var availableReleases: [HAOSRelease] = []
    @Published var selectedVersion: String?
    @Published private(set) var coreDownloadRegressed = false
    @Published private(set) var hasDisk = Paths.hasWorkingDisk
    @Published private(set) var guestOffline = false
    private var guestIP: String?
    private var repairingNetwork = false
    private var networkRepairAttempts = 0
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
        refreshReleases()
        if settings.startOnLaunch {
            Task { @MainActor in self.start() }
        }
    }

    func refreshDiskPresence() {
        hasDisk = Paths.hasWorkingDisk
    }

    func refreshReleases() {
        Task { [weak self] in
            guard let releases = try? await ImageDownloader.fetchReleases() else { return }
            await MainActor.run { self?.availableReleases = releases }
        }
    }

    var machineIsActive: Bool { machine != nil }
    var canErase: Bool { machine == nil && Paths.hasWorkingDisk }
    var hasDownloadedImage: Bool { ImageDownloader.cachedArchive != nil }

    func noteSettingsChanged() {
        objectWillChange.send()
    }

    // MARK: - Lifecycle

    func start() {
        guard machine == nil, !state.isBusy else { return }
        offerBootRepair = false
        coreDownloadRegressed = false
        guestOffline = false
        networkRepairAttempts = 0
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
                guard let self else { return }
                Task { @MainActor in self.machineDidStop(error: nil) }
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

    func erase(deletingDownloadedImage: Bool) {
        guard machine == nil else { return }
        pipeline?.cancel()
        pipeline = nil
        SavedSession.discard()
        console.clear()
        try? FileManager.default.removeItem(at: Paths.diskImage)
        try? FileManager.default.removeItem(at: Paths.efiStore)
        if deletingDownloadedImage, let archive = ImageDownloader.cachedArchive {
            try? FileManager.default.removeItem(at: archive)
        }
        offerBootRepair = false
        coreDownloadRegressed = false
        bootStartedAt = nil
        log.notice("erased machine (image kept: \(!deletingDownloadedImage, privacy: .public))")
        refreshDiskPresence()
        transition(.ready)
        refreshReleases()
    }

    // MARK: - Boot pipeline

    private func runPipeline() async {
        do {
            freshInstall = !Paths.hasWorkingDisk
            if !Paths.hasWorkingDisk {
                if needsImageDownload {
                    transition(.starting(.downloadingImage(percent: nil)), timeout: 3600)
                    let releases = try await ImageDownloader.fetchReleases()
                    availableReleases = releases
                    guard let release = releases.first(where: { $0.version == selectedVersion }) ?? releases.first else {
                        throw ImageDownloadError.assetMissing
                    }
                    log.notice("downloading HAOS \(release.version, privacy: .public)")
                    _ = try await ImageDownloader.download(release: release) { [weak self] percent in
                        guard let self else { return }
                        Task { @MainActor in self.updateImageDownloadPercent(percent) }
                    }
                }
                transition(.starting(.preparingDisk), timeout: 600)
                try await DiskBuilder.rebuild()
                refreshDiskPresence()
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
            guestIP = ip
            log.notice("guest reachable at \(ip, privacy: .public)")

            transition(.starting(.waitingForHomeAssistant(downloadPercent: nil)), timeout: 2400)
            startProgressPolling()
            let corePort = try await awaitCorePort(ip: ip)
            stopProgressPolling()
            log.notice("Home Assistant answering on port \(corePort, privacy: .public)")

            guard let url = URL(string: "http://\(ip):\(corePort)/") else {
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


    private func awaitCorePort(ip: String) async throws -> Int {
        while true {
            try Task.checkCancellation()
            if let port = await HTTPProbe.coreServingPort(ip: ip) { return port }
            try await Task.sleep(for: .seconds(1.5))
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
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard case .starting(.waitingForHomeAssistant) = self.state, self.shell.isAtShell else { continue }
                self.console.send(SupervisorProbe.progressCommand)
            }
        }
    }

    private func stopProgressPolling() {
        progressPoll?.cancel()
        progressPoll = nil
    }

    private var needsImageDownload: Bool {
        guard Paths.sourceImage == nil else { return false }
        guard let cached = ImageDownloader.cachedArchive else { return true }
        guard let version = selectedVersion else { return false }
        return !cached.lastPathComponent.contains("-\(version).img.xz")
    }

    private func updateImageDownloadPercent(_ percent: Int) {
        guard case .starting(.downloadingImage(let current)) = state, percent > (current ?? -1) else { return }
        transition(.starting(.downloadingImage(percent: percent)), timeout: 3600)
    }

    private func handleConsoleLine(_ line: String) {
        shell.handleLine(line)
        guard case .starting(.waitingForHomeAssistant(let current)) = state else { return }
        if let percent = SupervisorLog.downloadPercent(in: line) {
            guestOffline = false
            if percent != current {
                if let current, percent < current - 2 { coreDownloadRegressed = true }
                transition(.starting(.waitingForHomeAssistant(downloadPercent: percent)), timeout: 2400)
            }
            return
        }
        if SupervisorLog.reportsNoInternet(line), !guestOffline {
            guestOffline = true
            log.error("guest reports no internet connectivity")
            if networkRepairAttempts == 0 { repairGuestNetwork() }
        }
    }

    /// Points the guest's resolver at the Mac's VM gateway, which forwards DNS
    /// reliably, then restarts the guest's DNS and Supervisor so the stalled
    /// Core download starts.
    func repairGuestNetwork() {
        guard !repairingNetwork, shell.isAtShell, let ip = guestIP,
              let gateway = GuestNetwork.gatewayAddress(forGuestIP: ip) else { return }
        repairingNetwork = true
        networkRepairAttempts += 1
        log.notice("repairing guest DNS via gateway \(gateway, privacy: .public)")
        shell.run(GuestNetwork.repairCommand(gateway: gateway)) { [weak self] in
            self?.repairingNetwork = false
            self?.guestOffline = false
        }
    }

    var canRepairGuestNetwork: Bool { guestOffline && shell.isAtShell && !repairingNetwork }

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
