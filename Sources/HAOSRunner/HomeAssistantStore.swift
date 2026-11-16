import Foundation

/// What the app knows about the Home Assistant inside the machine, and the
/// things it can ask it to do.
@MainActor
final class HomeAssistantStore: ObservableObject {
    /// Work in progress on one app, update or backup.
    struct Activity: Equatable {
        let title: String
        /// The finished share, 0 to 1, when Home Assistant reports one.
        var fraction: Double?
    }

    struct ResourceSample: Equatable {
        /// Nil for the first sample: processor use is a difference between two.
        let processor: Double?
        let memory: Double
        let memoryUsedBytes: UInt64
        let memoryTotalBytes: UInt64
    }

    /// Home Assistant's address while the machine is running.
    @Published private(set) var address: URL?
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var appDetails: [String: AppDetail] = [:]
    @Published private(set) var storeApps: [StoreApp] = []
    @Published private(set) var system: SystemSummary?
    @Published private(set) var samples: [ResourceSample] = []
    @Published private(set) var backups: [Backup] = []
    @Published private(set) var activity: [String: Activity] = [:]
    @Published private(set) var hasLoadedApps = false
    @Published private(set) var hasLoadedStore = false
    @Published private(set) var hasLoadedBackups = false
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isLoadingLog = false

    /// Called with a sentence for the user when something they asked for fails.
    var onFailure: (String) -> Void = { _ in }

    static let newBackupKey = "backup:new"
    private static let sampleLimit = 60
    private static let logLineCount = 300

    private let client: SupervisorClient
    private var lastReading: ResourceReading?
    private var requestedLog: LogSource?

    init(client: SupervisorClient) {
        self.client = client
    }

    var isConnected: Bool { address != nil }

    var updates: [UpdateItem] {
        UpdateItem.list(info: system?.info, pending: system?.pending ?? [], apps: apps)
    }

    /// Store apps that are not installed, which is what the store section lists.
    var availableApps: [StoreApp] {
        storeApps.filter { !$0.installed }
    }

    // MARK: - Connection

    func connect(to address: URL) {
        self.address = address
        Task {
            await refreshSystem()
            await refreshApps()
            await refreshBackups()
        }
    }

    func disconnect() {
        address = nil
        apps = []
        appDetails = [:]
        storeApps = []
        system = nil
        samples = []
        backups = []
        activity = [:]
        hasLoadedApps = false
        hasLoadedStore = false
        hasLoadedBackups = false
        logLines = []
        lastReading = nil
        requestedLog = nil
    }

    // MARK: - Reading

    func refreshSystem() async {
        guard isConnected else { return }
        do {
            system = try await client.system()
        } catch {
            report("Could not read the system status", error)
        }
    }

    func refreshApps() async {
        guard isConnected else { return }
        do {
            let installed = try await client.apps()
            apps = installed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            hasLoadedApps = true
            for app in installed where appDetails[app.slug] == nil {
                appDetails[app.slug] = try? await client.detail(of: app.slug)
            }
        } catch {
            report("Could not read the installed apps", error)
        }
    }

    func refreshStore() async {
        guard isConnected else { return }
        do {
            storeApps = try await client.store()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            hasLoadedStore = true
        } catch {
            report("Could not read the app store", error)
        }
    }

    func refreshBackups() async {
        guard isConnected else { return }
        do {
            backups = try await client.backups().sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            hasLoadedBackups = true
        } catch {
            report("Could not read the backups", error)
        }
    }

    /// Keeps the Overview current until the calling task is cancelled:
    /// processor and memory every five seconds, versions and updates each minute.
    func watch() async {
        var tick = 0
        while !Task.isCancelled {
            if tick % 12 == 0 {
                await refreshSystem()
                await refreshApps()
            }
            await sampleResources()
            tick += 1
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func sampleResources() async {
        guard isConnected, let reading = try? await client.resources() else { return }
        let processor = lastReading.flatMap { reading.processorFraction(since: $0) }
        lastReading = reading
        samples.append(ResourceSample(
            processor: processor,
            memory: reading.memoryUsedFraction,
            memoryUsedBytes: reading.memoryUsedBytes,
            memoryTotalBytes: reading.memoryTotalBytes
        ))
        if samples.count > Self.sampleLimit {
            samples.removeFirst(samples.count - Self.sampleLimit)
        }
    }

    func loadLog(_ source: LogSource) async {
        requestedLog = source
        guard isConnected else {
            logLines = []
            return
        }
        isLoadingLog = true
        defer { isLoadingLog = false }
        do {
            let lines = try await client.log(source, lines: Self.logLineCount)
            // A slower answer for a source the user has since left is dropped.
            if requestedLog == source { logLines = lines }
        } catch {
            report("Could not read the \(source.title) log", error)
        }
    }

    // MARK: - Acting

    func activity(for app: String) -> Activity? {
        activity[UpdateItem.Target.app(slug: app).key]
    }

    func perform(_ verb: AppVerb, slug: String, name: String) {
        let (title, failure) = switch verb {
        case .install: ("Installing", "Could not install \(name)")
        case .uninstall: ("Uninstalling", "Could not uninstall \(name)")
        case .start: ("Starting", "Could not start \(name)")
        case .stop: ("Stopping", "Could not stop \(name)")
        case .restart: ("Restarting", "Could not restart \(name)")
        case .update: ("Updating", "Could not update \(name)")
        }
        run(UpdateItem.Target.app(slug: slug).key, title: title, reference: slug, failure: failure) {
            try GuestCommand.app(verb, slug: slug)
        } then: { [weak self] in
            if verb == .uninstall { self?.appDetails[slug] = nil }
            await self?.refreshApps()
            await self?.refreshStore()
            await self?.refreshSystem()
        }
    }

    func apply(_ update: UpdateItem) {
        let command: String
        switch update.target {
        case .app(let slug):
            perform(.update, slug: slug, name: update.name)
            return
        case .core: command = GuestCommand.updateCore
        case .operatingSystem: command = GuestCommand.updateOperatingSystem
        case .supervisor: command = GuestCommand.updateSupervisor
        }
        run(update.target.key, title: "Updating", failure: "Could not update \(update.name)") {
            command
        } then: { [weak self] in
            await self?.refreshSystem()
        }
    }

    func createBackup(named name: String) {
        run(Self.newBackupKey, title: "Creating backup", failure: "Could not create the backup") {
            GuestCommand.newBackup(named: name)
        } then: { [weak self] in
            await self?.refreshBackups()
        }
    }

    func restore(_ backup: Backup) {
        run("backup:\(backup.slug)", title: "Restoring", failure: "Could not restore \(backup.name)") {
            try GuestCommand.backup(.restore, slug: backup.slug)
        } then: { [weak self] in
            await self?.refreshSystem()
            await self?.refreshApps()
            await self?.refreshBackups()
        }
    }

    func delete(_ backup: Backup) {
        run("backup:\(backup.slug)", title: "Deleting", failure: "Could not delete \(backup.name)") {
            try GuestCommand.backup(.remove, slug: backup.slug)
        } then: { [weak self] in
            await self?.refreshBackups()
        }
    }

    private func run(
        _ key: String,
        title: String,
        reference: String? = nil,
        failure: String,
        command: () throws -> String,
        then refresh: @escaping () async -> Void
    ) {
        guard isConnected, activity[key] == nil else { return }
        let text: String
        do {
            text = try command()
        } catch {
            report(failure, error)
            return
        }
        activity[key] = Activity(title: title)
        Task {
            do {
                try await client.perform(text, reference: reference) { [weak self] fraction in
                    self?.activity[key]?.fraction = fraction
                }
            } catch {
                report(failure, error)
            }
            activity[key] = nil
            await refresh()
        }
    }

    private func report(_ what: String, _ error: Error) {
        // A machine that was switched off explains itself.
        guard isConnected, error as? GuestShellError != .unavailable else { return }
        let reason = error.localizedDescription
        // Supervisor's own wording for every refusal made while it calls the
        // system unhealthy. Home names the reason and the remedy.
        let pointer = reason.contains("system is not healthy") ? " Home explains how to fix this." : ""
        onFailure("\(what). \(reason)\(pointer)")
    }
}
