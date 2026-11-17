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
    @Published private(set) var guestDownload: SupervisorLog.Download?
    @Published private(set) var bridgeUnavailable = false
    @Published private(set) var sharing: PortForwarder.State = .stopped
    /// Home Assistant's address for other devices, while the port is shared.
    @Published private(set) var sharedAddress: URL?
    @Published private(set) var opensAtLogin = false
    /// USB devices plugged into this Mac, or nil when this build cannot hand
    /// any to the machine.
    @Published private(set) var usbDevices: [USBDevice]?
    /// A sentence about something that failed, shown until dismissed.
    @Published var notice: String?
    @Published var settings = VMSettings.load() {
        didSet {
            settings.save()
            applySharing()
            if settings.usbDevice != oldValue.usbDevice { syncUSB() }
            if settings.notifications, !oldValue.notifications {
                Task { _ = await Notifier.requestPermission() }
            }
        }
    }

    let home: HomeAssistantStore
    let snapshots: SnapshotLibrary

    private let console = SerialConsole.shared
    private let shell: GuestShell
    private let forwarder = PortForwarder()
    private let log = Logger(subsystem: "casa.astrohome.haosrunner", category: "controller")
    private var machine: VZVirtualMachine?
    private var pipeline: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var progressPoll: Task<Void, Never>?
    private var silenceWatch: Task<Void, Never>?
    private var vmStateObservation: NSKeyValueObservation?
    private var quitCompletion: (() -> Void)?
    /// Set while a restart's shutdown is under way, so the machine starts
    /// again once it is off.
    private var restartWhenStopped = false
    /// A `USBDevices` on macOS 27 builds that can pass devices through.
    private var usbWatcher: AnyObject?
    private var usbSync: Task<Void, Never>?

    private override init() {
        let shell = GuestShell { [console] text in console.send(text, visible: false) }
        self.shell = shell
        home = HomeAssistantStore(client: SupervisorClient(send: { command, timeout in
            try await shell.capture(command, timeout: timeout)
        }))
        snapshots = SnapshotLibrary(files: .current)
        super.init()
        console.onLine = { [weak self] line in self?.handleConsoleLine(line) ?? false }
        console.onTail = { [weak self] tail in self?.shell.handleTail(tail) }
        home.onFailure = { [weak self] message in
            self?.log.error("\(message, privacy: .public)")
            self?.notice = message
        }
        forwarder.onStateChange = { [weak self] state in
            Task { @MainActor in self?.sharingChanged(to: state) }
        }
        opensAtLogin = LoginItem.isEnabled
        if #available(macOS 27, *), USBPassthrough.isAvailable { watchUSB() }
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

    /// Whether the machine's disk can be copied or replaced right now.
    var canManageSnapshots: Bool { machine == nil && !state.isBusy && !snapshots.isWorking }

    /// What the window shows about the machine, as plain values.
    var status: MachineStatus {
        MachineStatus(
            state: state,
            hasDisk: hasDisk,
            isActive: machine != nil,
            bootStartedAt: bootStartedAt,
            freshInstall: freshInstall,
            downloadRegressed: coreDownloadRegressed,
            guestOffline: guestOffline,
            download: guestDownload,
            bridgeUnavailable: bridgeUnavailable,
            offerBootRepair: offerBootRepair,
            canResume: machine == nil && SavedSession.exists && SavedSession.matches(settings),
            sharing: sharing,
            sharedAddress: sharedAddress
        )
    }
    var hasDownloadedImage: Bool { ImageDownloader.cachedArchive != nil }

    func noteSettingsChanged() {
        objectWillChange.send()
    }

    // MARK: - Lifecycle

    func start() {
        guard machine == nil, !state.isBusy, !snapshots.isWorking else { return }
        offerBootRepair = false
        coreDownloadRegressed = false
        guestOffline = false
        guestDownload = nil
        console.clear()
        try? Paths.ensureSupportDirectory()
        console.beginFileLog(at: Paths.support.appending(path: "console.log"))
        shell.reset()
        bootStartedAt = .now
        pipeline = Task { await runPipeline() }
    }

    func stop() {
        guard let vm = machine else {
            forceStop()
            return
        }
        // Ask through the shell while the app is logged in to the guest; it
        // stays logged in so the request can be typed.
        let canAskGuest = shell.isAtShell
        guard canAskGuest || vm.canRequestStop else {
            forceStop()
            return
        }
        cancelBootWork(keepingShell: canAskGuest)
        transition(.stopping, timeout: 120)
        if canAskGuest {
            log.notice("asking the guest to shut down")
            shell.run(GuestCommand.shutdown)
            return
        }
        do {
            try vm.requestStop()
        } catch {
            fail("Home Assistant did not accept the shutdown request: \(error.localizedDescription)")
        }
    }

    /// Shuts the machine down cleanly and starts it again from cold.
    ///
    /// Resuming a suspended session brings back the same running system, so
    /// anything that only happens at boot, such as the data disk check, needs
    /// this instead.
    func restart() {
        guard machine != nil, case .running = state else { return }
        log.notice("restarting")
        restartWhenStopped = true
        stop()
    }

    func forceStop() {
        restartWhenStopped = false
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
        restartWhenStopped = false
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
            syncUSB()
            shell.begin()
            if resumed { shell.requestPrompt() }
            startSilenceWatch()

            transition(.starting(.waitingForNetwork), timeout: 240)
            let ip = try await awaitGuestIP()
            log.notice("guest reachable at \(ip, privacy: .public)")

            transition(.starting(.waitingForHomeAssistant(downloadPercent: nil)), timeout: Self.coreWaitTimeout)
            startProgressPolling()
            let corePort = try await awaitCorePort(ip: ip)
            stopProgressPolling()
            log.notice("Home Assistant answering on port \(corePort, privacy: .public)")

            transition(.starting(.connectingBridge), timeout: 600)
            let bridged = await establishBridge(ip: ip, corePort: corePort)
            bridgeUnavailable = !bridged
            let port = bridged ? RelayInstall.port : corePort
            guard let url = URL(string: "http://\(ip):\(port)/") else {
                throw PipelineFailure(message: "The guest address \(ip) is not a valid URL host.")
            }
            transition(.running(url: url))
            log.notice("running at \(url.absoluteString, privacy: .public) bridged=\(bridged, privacy: .public)")
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
            if #available(macOS 27, *), let usb {
                await usbSync?.value
                try await usb.disconnect()
            }
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


    /// Installs the loopback bridge if it is not already answering. It survives
    /// guest reboots, so warm starts skip straight past this. If it cannot be
    /// installed (the guest needs Docker Hub for the socat image), the machine
    /// still runs and Core's own address is surfaced, with the UI saying the
    /// interface may not work until the bridge is in place.
    private func establishBridge(ip: String, corePort: Int) async -> Bool {
        if await HTTPProbe.relayAnswers(ip: ip) { return true }
        guard shell.isAtShell else { return false }
        shell.run(RelayInstall.command(corePort: corePort))
        for _ in 0..<90 {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(4))
            if await HTTPProbe.relayAnswers(ip: ip) { return true }
        }
        log.error("bridge could not be installed; surfacing Home Assistant's own address")
        return false
    }

    private func awaitCorePort(ip: String) async throws -> Int {
        while true {
            try Task.checkCancellation()
            if let port = await HTTPProbe.coreServingPort(ip: ip) { return port }
            try await Task.sleep(for: .seconds(1.5))
        }
    }

    // MARK: - Progress

    private static let coreWaitTimeout: TimeInterval = 2400

    private func startProgressPolling() {
        progressPoll?.cancel()
        progressPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard case .starting(.waitingForHomeAssistant) = self.state, self.shell.isIdle else { continue }
                self.shell.run(SupervisorProbe.progressCommand, timeout: 30)
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

    /// - Returns: whether the line is the app's own command traffic.
    private func handleConsoleLine(_ line: String) -> Bool {
        let appTraffic = shell.handleLine(line)
        noteBootProgress(line)
        return appTraffic
    }

    private func noteBootProgress(_ line: String) {
        guard case .starting(.waitingForHomeAssistant(let current)) = state else { return }
        if let percent = SupervisorLog.downloadPercent(in: line) {
            guestOffline = false
            if percent != current {
                if let current, percent < current - 2 { coreDownloadRegressed = true }
                transition(.starting(.waitingForHomeAssistant(downloadPercent: percent)), timeout: Self.coreWaitTimeout)
            }
            return
        }
        guard SupervisorLog.isRecord(line) else { return }
        noteSupervisorRecord(line)
    }

    /// The poll returns Supervisor's newest record, so each one replaces what
    /// was known before: a download or an offline report holds only until
    /// Supervisor says something else.
    private func noteSupervisorRecord(_ line: String) {
        let offline = SupervisorLog.reportsNoInternet(line)
        if offline, !guestOffline { log.error("Supervisor reports no internet connectivity") }
        guestOffline = offline

        let download = SupervisorLog.download(in: line)
        if let download, download != guestDownload {
            log.notice("Supervisor downloading \(download.component, privacy: .public) \(download.version, privacy: .public)")
        }
        guestDownload = download
        // One image can take longer than the whole stage allows on a slow
        // route, and Supervisor logs nothing while it downloads. A poll that
        // still shows the download as the newest record restarts the clock.
        if download != nil { armWatchdog(timeout: Self.coreWaitTimeout) }
    }

    // MARK: - State

    private func transition(_ new: VMState, timeout: TimeInterval? = nil) {
        watchdog?.cancel()
        watchdog = nil
        let old = state
        if old.phase != new.phase { stageStartedAt = .now }
        state = new
        log.notice("state \(new.phase, privacy: .public)")
        if old.phase != new.phase { phaseChanged(from: old, to: new) }
        guard let timeout else { return }
        armWatchdog(timeout: timeout)
    }

    private func phaseChanged(from old: VMState, to new: VMState) {
        if case .running(let url) = new {
            home.connect(to: url)
            notify("Home Assistant is running", url.absoluteString)
        } else if case .running = old {
            home.disconnect()
        }
        if case .failed(let message) = new, case .starting = old {
            notify("Home Assistant did not start", message)
        }
        applySharing()
    }

    private func notify(_ title: String, _ body: String) {
        guard settings.notifications else { return }
        Notifier.post(title: title, body: body)
    }

    private func armWatchdog(timeout: TimeInterval) {
        watchdog?.cancel()
        let phase = state.phase
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
            fail("\(stage.title) has not finished after \(minutes) minutes. The console may show why. Force stop powers the machine off.")
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
                    + "Repair startup resets it and tries again. Your Home Assistant data is untouched."
            )
        }
    }

    // MARK: - Console

    /// Sends what the user typed in the console to the guest.
    func sendConsoleCommand(_ text: String) {
        shell.noteUserInput()
        console.send(text)
    }

    // MARK: - Sharing and login

    private func applySharing() {
        guard settings.shareOnNetwork, !settings.bridgedNetworking,
              case .running(let url) = state, let host = url.host(), let port = url.port else {
            forwarder.stop()
            return
        }
        forwarder.start(port: VMSettings.sharePort, host: host, targetPort: UInt16(port))
    }

    private func sharingChanged(to new: PortForwarder.State) {
        guard new != sharing else { return }
        sharing = new
        if case .listening(let port) = new, let address = LocalNetwork.address() {
            sharedAddress = URL(string: "http://\(address):\(port)/")
        } else {
            sharedAddress = nil
        }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            notice = "Could not change the login item. \(error.localizedDescription)"
        }
        opensAtLogin = LoginItem.isEnabled
    }

    // MARK: - Snapshots

    func takeSnapshot() {
        guard canManageSnapshots, Paths.hasWorkingDisk else { return }
        let name = Date.now.formatted(date: .abbreviated, time: .shortened)
        Task {
            do {
                try await snapshots.take(named: name, suspendedSession: SavedSession.recordedFingerprint)
            } catch {
                notice = "Could not take the snapshot. \(error.localizedDescription)"
            }
        }
    }

    func restoreSnapshot(_ snapshot: DiskSnapshot) {
        guard canManageSnapshots else { return }
        Task {
            do {
                try await snapshots.restore(snapshot)
                if let fingerprint = snapshot.suspendedSession {
                    SavedSession.adopt(fingerprint: fingerprint)
                } else {
                    SavedSession.discard()
                }
                offerBootRepair = false
                refreshDiskPresence()
                transition(.ready)
                log.notice("restored snapshot \(snapshot.name, privacy: .public)")
            } catch {
                notice = "Could not restore the snapshot. \(error.localizedDescription)"
            }
        }
    }

    func deleteSnapshot(_ snapshot: DiskSnapshot) {
        Task {
            do {
                try await snapshots.delete(snapshot)
            } catch {
                notice = "Could not delete the snapshot. \(error.localizedDescription)"
            }
        }
    }

    func repairAndRestart() {
        guard machine == nil, !snapshots.isWorking else { return }
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

    /// - Parameter keepingShell: leaves the app logged in to the guest, for a
    ///   shutdown that is about to be typed there.
    private func cancelBootWork(keepingShell: Bool = false) {
        pipeline?.cancel()
        pipeline = nil
        silenceWatch?.cancel()
        silenceWatch = nil
        stopProgressPolling()
        if !keepingShell { shell.reset() }
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
        if #available(macOS 27, *) { usb?.machineStopped() }
        bootStartedAt = nil
        if let error {
            fail(error.localizedDescription)
        } else if case .failed = state {
        } else {
            transition(.stopped)
        }
        finishQuit()
        let restarting = restartWhenStopped
        restartWhenStopped = false
        if restarting, case .stopped = state { start() }
    }

    private func finishQuit() {
        guard let completion = quitCompletion else { return }
        quitCompletion = nil
        completion()
    }

    // MARK: - USB devices

    @available(macOS 27, *)
    private var usb: USBDevices? { usbWatcher as? USBDevices }

    @available(macOS 27, *)
    private func watchUSB() {
        let usb = USBDevices()
        usbWatcher = usb
        usbDevices = []
        usb.onChange = { [weak self] in
            guard let self, let usb = self.usb else { return }
            self.usbDevices = usb.connected.map(\.device)
            self.syncUSB()
        }
        Task {
            do {
                try await usb.start()
            } catch {
                notice = "Annex could not list USB devices: \(error.localizedDescription)"
            }
        }
    }

    /// Brings the machine's USB device in line with the chosen one. One change
    /// runs at a time, because each waits on the machine and two interleaved
    /// would plug the same device in twice.
    private func syncUSB() {
        guard #available(macOS 27, *), let usb else { return }
        let previous = usbSync
        usbSync = Task { [weak self] in
            await previous?.value
            // While quitting, the device has been unplugged for the suspend
            // and must stay out of the saved session.
            guard let self, self.quitCompletion == nil, let vm = self.machine, vm.state == .running else { return }
            let choice = self.settings.usbDevice
            do {
                try await usb.connect(choice, to: vm)
            } catch {
                self.notice = "\(choice?.name ?? "The USB device") could not be handed to Home Assistant: \(error.localizedDescription)"
            }
        }
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
