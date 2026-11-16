import Foundation

/// A failure reported by Home Assistant, in its own words.
struct SupervisorError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

// MARK: - What Home Assistant reports

/// An app installed in Home Assistant.
struct InstalledApp: Decodable, Identifiable, Equatable {
    let slug: String
    let name: String
    let description: String
    let version: String?
    let versionLatest: String?
    let updateAvailable: Bool
    let state: String

    var id: String { slug }
    var isRunning: Bool { state == "started" }
}

/// An app offered by the Home Assistant store.
struct StoreApp: Decodable, Identifiable, Equatable {
    let slug: String
    let name: String
    let description: String
    let versionLatest: String?
    let installed: Bool
    let available: Bool

    var id: String { slug }
}

/// How an installed app's own web page is reached, if it has one.
struct AppDetail: Decodable, Equatable {
    let ingress: Bool
    let webui: String?
}

struct SystemInfo: Decodable, Equatable {
    let supervisor: String?
    let homeassistant: String?
    let hassos: String?
}

/// Disk figures for the guest, in gigabytes.
struct HostInfo: Decodable, Equatable {
    let diskTotal: Double?
    let diskUsed: Double?
}

struct PendingUpdate: Decodable, Equatable {
    let updateType: String
    let versionLatest: String?
}

/// Everything the Overview shows about the system, read in one round trip.
struct SystemSummary: Equatable {
    let info: SystemInfo
    let host: HostInfo
    let pending: [PendingUpdate]
    /// Home Assistant's reasons for calling the system unhealthy. While there
    /// are any, it refuses to install or update anything.
    let unhealthy: [String]
}

enum HealthAdvice {
    /// Whether restarting the machine clears every reason given.
    ///
    /// The data disk is checked once per boot. When that check is cut short
    /// (seen on 2026-11-15, after a boot that followed a lost session),
    /// Supervisor holds it against the system until a boot where it completes.
    static func restartClears(_ reasons: [String]) -> Bool {
        reasons == ["data_filesystem_check_error"]
    }

    /// What to tell the user about an unhealthy system, or nil when it is healthy.
    static func text(for reasons: [String]) -> String? {
        guard !reasons.isEmpty else { return nil }
        if restartClears(reasons) {
            return "Home Assistant could not finish checking its data disk when it last started, so it will not "
                + "install or update anything. Restart it to run the check again. Quitting the app does not do this: "
                + "it pauses Home Assistant and the next start resumes it as it was."
        }
        return "Home Assistant reports the system as unhealthy (\(reasons.joined(separator: ", "))) and will not "
            + "install or update anything. Its Repairs page, under Settings, explains what to do."
    }
}

/// A backup made by Home Assistant inside the guest.
struct Backup: Decodable, Identifiable, Equatable {
    let slug: String
    let name: String
    let date: String
    let type: String
    /// Megabytes.
    let size: Double?

    var id: String { slug }

    var createdAt: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: self.date) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: self.date)
    }
}

/// A unit of work Supervisor is doing, with the share of it that is finished.
struct SupervisorJob: Decodable, Equatable {
    let reference: String?
    let progress: Double?
    let done: Bool?
    let childJobs: [SupervisorJob]?
}

enum JobProgress {
    /// The finished share, 0 to 1, of the running job for `reference`, or of
    /// the only running job when none carries that reference.
    static func fraction(in jobs: [SupervisorJob], reference: String?) -> Double? {
        let active = flattened(jobs).filter { $0.done != true && ($0.progress ?? 0) > 0 }
        let match = active.first { reference != nil && $0.reference == reference } ?? active.first
        return match?.progress.map { min(1, $0 / 100) }
    }

    private static func flattened(_ jobs: [SupervisorJob]) -> [SupervisorJob] {
        jobs.flatMap { [$0] + flattened($0.childJobs ?? []) }
    }
}

/// Something with a newer version waiting.
struct UpdateItem: Identifiable, Equatable {
    enum Target: Hashable {
        case core
        case operatingSystem
        case supervisor
        case app(slug: String)

        /// The name the store tracks this target's running work under.
        var key: String {
            switch self {
            case .core: "core"
            case .operatingSystem: "os"
            case .supervisor: "supervisor"
            case .app(let slug): "app:\(slug)"
            }
        }
    }

    let target: Target
    let name: String
    let installed: String?
    let latest: String

    var id: Target { target }

    static func list(info: SystemInfo?, pending: [PendingUpdate], apps: [InstalledApp]) -> [UpdateItem] {
        let system: [UpdateItem] = pending.compactMap { update in
            guard let latest = update.versionLatest else { return nil }
            switch update.updateType {
            case "core":
                return UpdateItem(target: .core, name: "Home Assistant Core", installed: info?.homeassistant, latest: latest)
            case "os":
                return UpdateItem(target: .operatingSystem, name: "Operating system", installed: info?.hassos, latest: latest)
            case "supervisor":
                return UpdateItem(target: .supervisor, name: "Supervisor", installed: info?.supervisor, latest: latest)
            default:
                return nil
            }
        }
        let appUpdates: [UpdateItem] = apps.compactMap { app in
            guard app.updateAvailable, let latest = app.versionLatest else { return nil }
            return UpdateItem(target: .app(slug: app.slug), name: app.name, installed: app.version, latest: latest)
        }
        return system + appUpdates
    }
}

/// One reading of the guest's processor counters and memory.
struct ResourceReading: Equatable {
    let busyTicks: UInt64
    let totalTicks: UInt64
    let memoryTotalKB: UInt64
    let memoryAvailableKB: UInt64

    var memoryUsedFraction: Double {
        guard memoryTotalKB > 0 else { return 0 }
        return Double(memoryTotalKB - min(memoryAvailableKB, memoryTotalKB)) / Double(memoryTotalKB)
    }

    var memoryUsedBytes: UInt64 { (memoryTotalKB - min(memoryAvailableKB, memoryTotalKB)) * 1024 }
    var memoryTotalBytes: UInt64 { memoryTotalKB * 1024 }

    /// The share of processor time spent working since an earlier reading.
    /// The counters only ever grow, so use is the difference between two.
    func processorFraction(since earlier: ResourceReading) -> Double? {
        guard totalTicks > earlier.totalTicks, busyTicks >= earlier.busyTicks else { return nil }
        return Double(busyTicks - earlier.busyTicks) / Double(totalTicks - earlier.totalTicks)
    }

    /// Reads the first line of `/proc/stat` and two lines of `/proc/meminfo`.
    static func parse(_ output: String) -> ResourceReading? {
        var ticks: [UInt64] = []
        var memory: [String: UInt64] = [:]
        for line in output.components(separatedBy: "\n") {
            let fields = line.split(separator: " ")
            guard let label = fields.first else { continue }
            if label == "cpu" {
                ticks = fields.dropFirst().compactMap { UInt64($0) }
            } else if label.hasSuffix(":"), fields.count >= 2, let value = UInt64(fields[1]) {
                memory[String(label.dropLast())] = value
            }
        }
        guard ticks.count >= 5, let total = memory["MemTotal"], let available = memory["MemAvailable"] else {
            return nil
        }
        // Fields 3 and 4 are idle and waiting-on-disk time.
        let sum = ticks.reduce(0, +)
        return ResourceReading(
            busyTicks: sum - ticks[3] - ticks[4],
            totalTicks: sum,
            memoryTotalKB: total,
            memoryAvailableKB: available
        )
    }
}

enum AppWebPage {
    /// The address that opens an installed app's own page in the browser.
    static func url(slug: String, detail: AppDetail, homeAssistant: URL) -> URL? {
        if detail.ingress {
            // Home Assistant's own page for the app, which shows the app's
            // interface inside Home Assistant. There is no My Home Assistant
            // redirect for this since add-ons were renamed apps.
            return homeAssistant.appending(path: "app/\(slug)")
        }
        guard let template = detail.webui, let host = homeAssistant.host() else { return nil }
        return URL(string: template.replacingOccurrences(of: "[HOST]", with: host))
    }

    /// The app's page inside Home Assistant, where it is configured.
    static func settingsURL(slug: String, homeAssistant: URL) -> URL {
        homeAssistant
            .appending(path: "_my_redirect/supervisor_addon")
            .appending(queryItems: [URLQueryItem(name: "addon", value: slug)])
    }

    static func iconURL(slug: String, homeAssistant: URL) -> URL {
        homeAssistant.appending(path: "api/hassio/addons/\(slug)/icon")
    }
}

// MARK: - What the app types

enum AppVerb: String {
    case install, uninstall, start, stop, restart, update
}

enum BackupVerb: String {
    case restore, remove
}

enum LogSource: Hashable {
    case core
    case supervisor
    case host
    case app(slug: String, name: String)

    var title: String {
        switch self {
        case .core: "Home Assistant Core"
        case .supervisor: "Supervisor"
        case .host: "Operating system"
        case .app(_, let name): name
        }
    }
}

/// The exact text typed into the guest's shell for each thing the app asks.
enum GuestCommand {
    private static let flags = "--raw-json --no-progress"

    static let apps = "ha apps \(flags)"
    static let store = "ha store \(flags)"
    /// `ha` ends an answer without a line break, so the bare `echo` between
    /// the calls is what puts each answer on a line of its own.
    static let system = "ha info \(flags); echo; ha host info \(flags); echo; "
        + "ha available-updates \(flags); echo; ha resolution info \(flags)"
    static let backups = "ha backups \(flags)"
    static let jobs = "ha jobs info \(flags)"
    static let resources = "head -n1 /proc/stat; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo"
    static let updateCore = "ha core update \(flags)"
    static let updateOperatingSystem = "ha os update \(flags)"
    static let updateSupervisor = "ha supervisor update \(flags)"
    /// Shuts the guest down in order: Supervisor stops Home Assistant and the
    /// apps, then powers off. Home Assistant OS ignores the short power-button
    /// press a virtual machine's stop request sends (its logind is set to
    /// HandlePowerKey=ignore), so this is the only clean way to turn it off.
    static let shutdown = "ha host shutdown --no-progress"

    static func appInfo(_ slug: String) throws -> String {
        let name = try identifier(slug)
        return "ha apps info \(name) \(flags)"
    }

    static func app(_ verb: AppVerb, slug: String) throws -> String {
        let name = try identifier(slug)
        return "ha apps \(verb.rawValue) \(name) \(flags)"
    }

    static func newBackup(named name: String) -> String {
        "ha backups new --name \(quoted(name)) \(flags)"
    }

    static func backup(_ verb: BackupVerb, slug: String) throws -> String {
        let name = try identifier(slug)
        return "ha backups \(verb.rawValue) \(name) \(flags)"
    }

    /// Logs are read from whatever wrote them, not through `ha … logs`:
    /// Supervisor's log formatter stops at any journal entry it cannot read
    /// and then returns an old, cut-off log ending in "unexpected EOF".
    static func log(_ source: LogSource, lines: Int) throws -> String {
        switch source {
        case .core:
            return "docker logs --tail \(lines) homeassistant 2>&1"
        case .supervisor:
            return "docker logs --tail \(lines) hassio_supervisor 2>&1"
        case .host:
            return "journalctl -n \(lines) --no-pager 2>&1"
        case .app(let slug, _):
            // The container is `app_<slug>`, or `addon_<slug>` on older
            // versions, so it is looked up by the suffix both share. The
            // subshell keeps `c` out of the user's shell.
            let name = try identifier(slug)
            return "( c=$(docker ps -aq --filter 'name=_\(name)$' | head -n1); "
                + "[ -n \"$c\" ] && docker logs --tail \(lines) \"$c\" 2>&1 )"
        }
    }

    /// Identifiers come from Home Assistant's own answers, but they are typed
    /// into a root shell, so anything that is not a plain name is refused.
    static func identifier(_ raw: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !raw.isEmpty, raw.count <= 64, raw.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SupervisorError(message: "Home Assistant returned a name the app will not pass to the shell: \(raw)")
        }
        return raw
    }

    /// Wraps free text so the shell reads it as one literal word.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A command that can run for minutes, started in the background inside the
/// guest so the console stays free for everything else.
enum GuestJob {
    enum Status: Equatable {
        case running
        case finished(exitCode: Int, output: String)
        /// The guest restarted and took the job's record with it.
        case lost
    }

    private static func files(_ token: String) -> (output: String, exitCode: String) {
        ("/tmp/haosrunner-\(token).out", "/tmp/haosrunner-\(token).rc")
    }

    /// The inner subshell is backgrounded by an outer one that exits at once,
    /// so the interactive shell never tracks it and prints no job notices.
    static func launch(_ command: String, token: String) -> String {
        let (output, exitCode) = files(token)
        return "( ( \(command) > \(output) 2>&1; echo $? > \(exitCode) ) & )"
    }

    static func collect(token: String) -> String {
        let (output, exitCode) = files(token)
        return "if [ -f \(exitCode) ]; then echo \"exit=$(cat \(exitCode))\"; cat \(output); rm -f \(exitCode) \(output); "
            + "elif [ -f \(output) ]; then echo running; else echo gone; fi"
    }

    static func status(from output: String) -> Status? {
        var lines = output.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        lines.removeFirst()
        if first == "running" { return .running }
        if first == "gone" { return .lost }
        guard first.hasPrefix("exit="), let code = Int(first.dropFirst(5)) else { return nil }
        return .finished(exitCode: code, output: lines.joined(separator: "\n"))
    }
}

/// Reads the answers the guest's `ha` command prints.
enum SupervisorReply {
    private struct Status: Decodable {
        let result: String
        let message: String?
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// The JSON answers in a command's output, one per `ha` call, in order.
    static func answers(in output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") }
    }

    static func decode<Payload: Decodable>(_ type: Payload.Type, from answer: String) throws -> Payload {
        let data = Data(answer.utf8)
        guard let status = try? decoder.decode(Status.self, from: data) else {
            throw SupervisorError(message: "Home Assistant sent an answer the app could not read.")
        }
        guard status.result == "ok" else {
            throw SupervisorError(message: status.message ?? "Home Assistant reported an error.")
        }
        do {
            return try decoder.decode(Envelope<Payload>.self, from: data).data
        } catch {
            throw SupervisorError(message: "Home Assistant sent an answer the app could not read.")
        }
    }

    /// Decodes the only answer in a command's output.
    static func single<Payload: Decodable>(_ type: Payload.Type, in output: String) throws -> Payload {
        guard let answer = answers(in: output).first else {
            throw SupervisorError(message: failure(in: output))
        }
        return try decode(type, from: answer)
    }

    /// Why a command failed, as a sentence for the user: Home Assistant's own
    /// message when it gave one, else the first line of plain text it printed.
    /// The data of an answer is never passed on as if it were a reason.
    static func failure(in output: String) -> String {
        let answers = answers(in: output)
        for answer in answers {
            if let status = try? decoder.decode(Status.self, from: Data(answer.utf8)),
               status.result != "ok", let message = status.message {
                return message
            }
        }
        let plainLine = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("{") }
        if let plainLine {
            let reason = plainLine.hasPrefix("Error: ") ? String(plainLine.dropFirst(7)) : plainLine
            return String(reason.prefix(300))
        }
        return answers.isEmpty
            ? "Home Assistant did not answer."
            : "Home Assistant sent an answer the app could not read."
    }

    /// Whether a finished command's output carries an error answer.
    static func reportsError(_ output: String) -> Bool {
        answers(in: output).contains { answer in
            guard let status = try? decoder.decode(Status.self, from: Data(answer.utf8)) else { return false }
            return status.result != "ok"
        }
    }
}

// MARK: - Client

/// Asks Home Assistant's Supervisor for things through the guest's `ha` command.
@MainActor
struct SupervisorClient {
    /// Runs one command in the guest and returns what it printed.
    typealias Transport = @MainActor (_ command: String, _ timeout: TimeInterval) async throws -> String

    private struct AppList: Decodable { let addons: [InstalledApp] }
    private struct StoreListing: Decodable { let addons: [StoreApp] }
    private struct UpdateList: Decodable { let availableUpdates: [PendingUpdate] }
    private struct Resolution: Decodable { let unhealthy: [String] }
    private struct BackupList: Decodable { let backups: [Backup] }
    private struct JobList: Decodable { let jobs: [SupervisorJob] }

    /// How many unanswered checks a long command survives. A guest restarting
    /// for an operating system update goes quiet for a minute or two.
    private static let patience = 20

    let send: Transport
    var pollInterval: Duration = .seconds(2)

    func apps() async throws -> [InstalledApp] {
        try SupervisorReply.single(AppList.self, in: try await send(GuestCommand.apps, 30)).addons
    }

    func store() async throws -> [StoreApp] {
        try SupervisorReply.single(StoreListing.self, in: try await send(GuestCommand.store, 60)).addons
    }

    func detail(of slug: String) async throws -> AppDetail {
        try SupervisorReply.single(AppDetail.self, in: try await send(try GuestCommand.appInfo(slug), 30))
    }

    func system() async throws -> SystemSummary {
        let output = try await send(GuestCommand.system, 45)
        let answers = SupervisorReply.answers(in: output)
        guard answers.count == 4 else { throw SupervisorError(message: SupervisorReply.failure(in: output)) }
        return SystemSummary(
            info: try SupervisorReply.decode(SystemInfo.self, from: answers[0]),
            host: try SupervisorReply.decode(HostInfo.self, from: answers[1]),
            pending: try SupervisorReply.decode(UpdateList.self, from: answers[2]).availableUpdates,
            unhealthy: try SupervisorReply.decode(Resolution.self, from: answers[3]).unhealthy
        )
    }

    func backups() async throws -> [Backup] {
        try SupervisorReply.single(BackupList.self, in: try await send(GuestCommand.backups, 30)).backups
    }

    func resources() async throws -> ResourceReading {
        let output = try await send(GuestCommand.resources, 15)
        guard let reading = ResourceReading.parse(output) else {
            throw SupervisorError(message: "The machine's resource counters could not be read.")
        }
        return reading
    }

    func log(_ source: LogSource, lines: Int) async throws -> [String] {
        let output = try await send(try GuestCommand.log(source, lines: lines), 45)
        return output.isEmpty ? [] : output.components(separatedBy: "\n")
    }

    /// Runs a command that can take minutes and returns once it has finished.
    ///
    /// - Parameters:
    ///   - reference: the name Supervisor files the work under, used to pick
    ///     its progress out of everything else that is running.
    ///   - progress: called with the finished share, 0 to 1, when it is known.
    func perform(
        _ command: String,
        reference: String? = nil,
        progress: (Double?) -> Void = { _ in }
    ) async throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        _ = try await send(GuestJob.launch(command, token: token), 30)
        var unanswered = 0
        while true {
            try await Task.sleep(for: pollInterval)
            let output: String
            do {
                output = try await send(GuestJob.collect(token: token), 30)
                unanswered = 0
            } catch GuestShellError.unavailable {
                throw GuestShellError.unavailable
            } catch {
                unanswered += 1
                guard unanswered < Self.patience else { throw error }
                continue
            }
            switch GuestJob.status(from: output) {
            case .finished(let exitCode, let printed):
                guard exitCode == 0, !SupervisorReply.reportsError(printed) else {
                    throw SupervisorError(message: SupervisorReply.failure(in: printed))
                }
                return
            case .lost:
                return
            case .running, nil:
                if let jobs = try? await jobs() {
                    progress(JobProgress.fraction(in: jobs, reference: reference))
                }
            }
        }
    }

    private func jobs() async throws -> [SupervisorJob] {
        try SupervisorReply.single(JobList.self, in: try await send(GuestCommand.jobs, 20)).jobs
    }
}
