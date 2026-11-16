import XCTest
@testable import HAOSRunner

/// Answers copied from a running Home Assistant OS 18.2 guest on 2026-11-14.
private enum Fixture {
    static let apps = #"{"result":"ok","data":{"addons":[{"name":"Tailscale","slug":"a0d7b954_tailscale","description":"Zero config VPN for building secure networks","stage":"stable","version":"0.29.0","version_latest":"0.30.0","update_available":true,"available":true,"detached":false,"homeassistant":null,"state":"started","repository":"a0d7b954","build":false,"url":"https://github.com/hassio-addons/app-tailscale","icon":true,"logo":true,"system_managed":false,"advanced":false}]}}"#

    static let store = #"{"result":"ok","data":{"addons":[{"advanced":false,"arch":["amd64","aarch64"],"available":true,"build":false,"description":"Build your own smart home devices using ESPHome, no programming experience required","documentation":true,"homeassistant":null,"icon":true,"installed":false,"logo":true,"name":"ESPHome Device Builder","repository":"5c53de3b","slug":"5c53de3b_esphome","stage":"stable","update_available":false,"url":"https://esphome.io/","version_latest":"2026.9.0","version":null},{"advanced":false,"arch":["aarch64","amd64"],"available":true,"build":false,"description":"Zero config VPN for building secure networks","documentation":true,"homeassistant":null,"icon":true,"installed":true,"logo":true,"name":"Tailscale","repository":"a0d7b954","slug":"a0d7b954_tailscale","stage":"stable","update_available":true,"url":"https://github.com/hassio-addons/app-tailscale","version_latest":"0.30.0","version":"0.29.0"}],"repositories":[]}}"#

    static let info = #"{"result":"ok","data":{"supervisor":"2026.11.0","homeassistant":"2026.9.0","hassos":"18.2","docker":"29.6.2","hostname":"homeassistant","operating_system":"Home Assistant OS 18.2","machine":"qemuarm-64","arch":"aarch64","state":"running","supported":false,"channel":"stable"}}"#

    static let host = #"{"result":"ok","data":{"agent_version":"1.10.0","chassis":"embedded","virtualization":"apple","disk_free":54.2,"disk_total":62.3,"disk_used":5.5,"disk_life_time":null,"hostname":"homeassistant","kernel":"6.18.39-haos"}}"#

    static let updates = #"{"result":"ok","data":{"available_updates":[{"update_type":"core","panel_path":"/update-available/core","version_latest":"2026.11.1"},{"update_type":"os","panel_path":"/update-available/os","version_latest":"18.4"},{"update_type":"addon","name":"Tailscale","icon":"/addons/a0d7b954_tailscale/icon","panel_path":"/update-available/a0d7b954_tailscale","version_latest":"0.30.0"}]}}"#

    /// From the guest on 2026-11-15, after a start whose disk check was cut short.
    static let resolution = #"{"result":"ok","data":{"unsupported":["software"],"unhealthy":["data_filesystem_check_error"],"suggestions":[{"type":"create_full_backup","context":"system","reference":null,"uuid":"5d32fc79edf5537c86f2a115f02a4fd0","auto":false}],"issues":[{"type":"no_current_backup","context":"system","reference":null,"uuid":"91fbf468525c5b0cbf3440bf9fdf1c81"}],"checks":[]}}"#

    static let noBackups = #"{"result":"ok","data":{"backups":[],"days_until_stale":30}}"#

    static let notReady = #"{"result":"error","message":"System is not ready with state: setup"}"#

    static let resources = """
    cpu  5020 0 3926 2011341 1360 2682 1407 0 0 0
    MemTotal:        4005344 kB
    MemAvailable:    2888532 kB
    """
}

/// Requirement: the app shows what Home Assistant itself reports, and when
/// Home Assistant refuses, the user reads its reason rather than a guess.
final class SupervisorReplyTests: XCTestCase {
    private struct AppList: Decodable { let addons: [InstalledApp] }
    private struct StoreListing: Decodable { let addons: [StoreApp] }

    func testInstalledAppsAreReadFromTheGuestAnswer() throws {
        let apps = try SupervisorReply.single(AppList.self, in: Fixture.apps).addons
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].slug, "a0d7b954_tailscale")
        XCTAssertEqual(apps[0].name, "Tailscale")
        XCTAssertEqual(apps[0].version, "0.29.0")
        XCTAssertEqual(apps[0].versionLatest, "0.30.0")
        XCTAssertTrue(apps[0].updateAvailable)
        XCTAssertTrue(apps[0].isRunning)
    }

    func testStoreListingSaysWhatIsAlreadyInstalled() throws {
        let store = try SupervisorReply.single(StoreListing.self, in: Fixture.store).addons
        XCTAssertEqual(store.map(\.slug), ["5c53de3b_esphome", "a0d7b954_tailscale"])
        XCTAssertEqual(store.map(\.installed), [false, true])
    }

    func testRefusalIsReportedInHomeAssistantsOwnWords() {
        XCTAssertThrowsError(try SupervisorReply.single(AppList.self, in: Fixture.notReady)) { error in
            XCTAssertEqual(error as? SupervisorError, SupervisorError(message: "System is not ready with state: setup"))
        }
    }

    func testPlainTextFailureIsReportedWithoutItsPrefix() {
        let output = "Error: connection refused\nsecond line"
        XCTAssertThrowsError(try SupervisorReply.single(AppList.self, in: output)) { error in
            XCTAssertEqual(error as? SupervisorError, SupervisorError(message: "connection refused"))
        }
    }

    func testOtherLinesAroundTheAnswerAreIgnored() throws {
        let output = "[ 4412.1] audit: something the kernel printed\n" + Fixture.apps
        XCTAssertEqual(try SupervisorReply.single(AppList.self, in: output).addons.count, 1)
    }

    /// A failure sentence is shown to the user, so it must never be the raw
    /// data of an answer that merely could not be used.
    func testFailureIsNeverTheRawAnswer() {
        XCTAssertEqual(
            SupervisorReply.failure(in: Fixture.info + Fixture.host),
            "Home Assistant sent an answer the app could not read."
        )
        XCTAssertEqual(SupervisorReply.failure(in: ""), "Home Assistant did not answer.")
    }

    func testFinishedCommandWithAnErrorAnswerCountsAsFailed() {
        XCTAssertTrue(SupervisorReply.reportsError(Fixture.notReady))
        XCTAssertFalse(SupervisorReply.reportsError(Fixture.noBackups))
        XCTAssertFalse(SupervisorReply.reportsError("Command completed successfully."))
    }
}

/// Requirement: nothing Home Assistant or the user supplies can change what
/// command runs in the guest's root shell.
final class GuestCommandTests: XCTestCase {
    func testAppCommandsNameTheAppAndAskForMachineReadableOutput() throws {
        XCTAssertEqual(
            try GuestCommand.app(.start, slug: "a0d7b954_tailscale"),
            "ha apps start a0d7b954_tailscale --raw-json --no-progress"
        )
    }

    /// Requirement: the Logs screen shows the newest lines. `ha core logs -n 300`
    /// did not on 2026-11-15: Supervisor's formatter stopped at a journal entry
    /// it could not read and returned 249 old lines ending "unexpected EOF",
    /// while the container's own log had the current 299.
    func testLogsAreReadStraightFromWhatWroteThem() throws {
        XCTAssertEqual(try GuestCommand.log(.core, lines: 50), "docker logs --tail 50 homeassistant 2>&1")
        XCTAssertEqual(try GuestCommand.log(.supervisor, lines: 50), "docker logs --tail 50 hassio_supervisor 2>&1")
        XCTAssertEqual(try GuestCommand.log(.host, lines: 50), "journalctl -n 50 --no-pager 2>&1")
    }

    /// An app's container was `addon_<slug>` and is `app_<slug>` since Home
    /// Assistant renamed add-ons, so it is found by the part that did not change.
    func testAppLogIsFoundWhateverPrefixItsContainerHas() throws {
        XCTAssertEqual(
            try GuestCommand.log(.app(slug: "core_mosquitto", name: "Mosquitto"), lines: 200),
            "( c=$(docker ps -aq --filter 'name=_core_mosquitto$' | head -n1); "
                + "[ -n \"$c\" ] && docker logs --tail 200 \"$c\" 2>&1 )"
        )
        XCTAssertThrowsError(try GuestCommand.log(.app(slug: "x$(reboot)", name: "x"), lines: 200))
    }

    /// `ha --raw-json` ends its answer without a line break (seen on HAOS 18.2
    /// with CLI output for both successes and errors), so answers asked for in
    /// one command arrive on one line unless something separates them.
    func testAnswersAskedForTogetherAreEachPutOnTheirOwnLine() {
        XCTAssertEqual(
            GuestCommand.system,
            "ha info --raw-json --no-progress; echo; "
                + "ha host info --raw-json --no-progress; echo; "
                + "ha available-updates --raw-json --no-progress; echo; "
                + "ha resolution info --raw-json --no-progress"
        )
    }

    /// Requirement: Stop shuts Home Assistant OS down cleanly. It ignores a
    /// short press of the power button that the virtual machine sends
    /// (logind HandlePowerKey=ignore, seen on 18.2 on 2026-11-15), so the app
    /// asks it to shut itself down instead.
    func testStopAsksHomeAssistantOSToShutItselfDown() {
        XCTAssertEqual(GuestCommand.shutdown, "ha host shutdown --no-progress")
    }

    func testNamesThatAreNotPlainIdentifiersNeverReachTheShell() {
        for slug in ["core_x; reboot", "$(reboot)", "a b", "", "x`id`", "a/../b"] {
            XCTAssertThrowsError(try GuestCommand.app(.install, slug: slug), slug)
            XCTAssertThrowsError(try GuestCommand.backup(.remove, slug: slug), slug)
            XCTAssertThrowsError(try GuestCommand.appInfo(slug), slug)
        }
    }

    func testBackupNameIsOneLiteralWordToTheShell() {
        XCTAssertEqual(
            GuestCommand.newBackup(named: "Bob's $(reboot) backup"),
            "ha backups new --name 'Bob'\\''s $(reboot) backup' --raw-json --no-progress"
        )
    }
}

/// Requirement: a long operation (an install, an update, a backup) must not
/// hold the console, and its outcome must survive the guest restarting.
final class GuestJobTests: XCTestCase {
    func testJobRunsInTheBackgroundAndRecordsItsOutcome() {
        let command = GuestJob.launch("ha apps install core_mosquitto", token: "ab12cd34")
        XCTAssertEqual(
            command,
            "( ( ha apps install core_mosquitto > /tmp/haosrunner-ab12cd34.out 2>&1; "
                + "echo $? > /tmp/haosrunner-ab12cd34.rc ) & )"
        )
    }

    func testCollectingTellsRunningFromFinishedFromLost() {
        XCTAssertEqual(GuestJob.status(from: "running"), .running)
        XCTAssertEqual(GuestJob.status(from: "gone"), .lost)
        XCTAssertEqual(
            GuestJob.status(from: "exit=0\n{\"result\":\"ok\",\"data\":{}}"),
            .finished(exitCode: 0, output: "{\"result\":\"ok\",\"data\":{}}")
        )
        XCTAssertEqual(GuestJob.status(from: "exit=1\nError: no"), .finished(exitCode: 1, output: "Error: no"))
        XCTAssertNil(GuestJob.status(from: "sh: something unexpected"))
    }

    func testProgressIsTakenFromTheJobForTheSameApp() {
        let jobs = [
            SupervisorJob(reference: "core_mosquitto", progress: 0, done: false, childJobs: [
                SupervisorJob(reference: "core_mosquitto", progress: 42, done: false, childJobs: nil),
            ]),
            SupervisorJob(reference: "other", progress: 90, done: false, childJobs: nil),
        ]
        XCTAssertEqual(JobProgress.fraction(in: jobs, reference: "core_mosquitto"), 0.42)
        XCTAssertEqual(JobProgress.fraction(in: jobs, reference: nil), 0.42)
        XCTAssertNil(JobProgress.fraction(in: [], reference: "core_mosquitto"))
    }
}

/// Requirement: the Overview shows the whole machine's processor and memory
/// use, read from the guest's own counters.
final class ResourceReadingTests: XCTestCase {
    func testCountersAreReadFromTheGuest() throws {
        let reading = try XCTUnwrap(ResourceReading.parse(Fixture.resources))
        XCTAssertEqual(reading.memoryTotalKB, 4_005_344)
        XCTAssertEqual(reading.memoryAvailableKB, 2_888_532)
        XCTAssertEqual(reading.memoryUsedFraction, 0.2788, accuracy: 0.0001)
        XCTAssertEqual(reading.totalTicks, 5020 + 3926 + 2_011_341 + 1360 + 2682 + 1407)
        XCTAssertEqual(reading.busyTicks, 5020 + 3926 + 2682 + 1407)
    }

    func testProcessorUseIsTheWorkDoneBetweenTwoReadings() {
        let earlier = ResourceReading(busyTicks: 100, totalTicks: 1000, memoryTotalKB: 1, memoryAvailableKB: 1)
        let later = ResourceReading(busyTicks: 150, totalTicks: 1200, memoryTotalKB: 1, memoryAvailableKB: 1)
        XCTAssertEqual(later.processorFraction(since: earlier), 0.25)
        XCTAssertNil(earlier.processorFraction(since: earlier))
    }

    func testUnreadableOutputGivesNoReading() {
        XCTAssertNil(ResourceReading.parse("sh: head: not found"))
    }
}

/// Requirement: "Open" on an installed app goes to that app's own page.
final class AppWebPageTests: XCTestCase {
    private let homeAssistant = URL(string: "http://192.168.64.22:9999/")!

    /// Home Assistant 2026.9 has no "supervisor_ingress" redirect any more
    /// (its redirect table, read from the guest on 2026-11-15, lists only
    /// supervisor_addon, supervisor_app and the store), and its frontend opens
    /// an app's page at /app/<slug>, which that guest serves.
    func testAppServedThroughHomeAssistantOpensOnItsAppPage() {
        let url = AppWebPage.url(
            slug: "a0d7b954_tailscale",
            detail: AppDetail(ingress: true, webui: nil),
            homeAssistant: homeAssistant
        )
        XCTAssertEqual(url?.absoluteString, "http://192.168.64.22:9999/app/a0d7b954_tailscale")
    }

    func testAppSettingsUseARedirectHomeAssistantStillHas() {
        XCTAssertEqual(
            AppWebPage.settingsURL(slug: "a0d7b954_tailscale", homeAssistant: homeAssistant).absoluteString,
            "http://192.168.64.22:9999/_my_redirect/supervisor_addon?addon=a0d7b954_tailscale"
        )
    }

    func testAppWithItsOwnPortOpensOnTheGuestAddress() {
        let url = AppWebPage.url(
            slug: "core_x",
            detail: AppDetail(ingress: false, webui: "http://[HOST]:8080/"),
            homeAssistant: homeAssistant
        )
        XCTAssertEqual(url?.absoluteString, "http://192.168.64.22:8080/")
    }

    func testAppWithoutAPageHasNothingToOpen() {
        XCTAssertNil(AppWebPage.url(
            slug: "core_x",
            detail: AppDetail(ingress: false, webui: nil),
            homeAssistant: homeAssistant
        ))
    }
}

/// Requirement: every pending update is listed with the version it replaces.
final class UpdateItemTests: XCTestCase {
    func testSystemAndAppUpdatesAreListedWithInstalledAndNewVersions() throws {
        struct UpdateList: Decodable { let availableUpdates: [PendingUpdate] }
        struct AppList: Decodable { let addons: [InstalledApp] }
        let items = UpdateItem.list(
            info: try SupervisorReply.single(SystemInfo.self, in: Fixture.info),
            pending: try SupervisorReply.single(UpdateList.self, in: Fixture.updates).availableUpdates,
            apps: try SupervisorReply.single(AppList.self, in: Fixture.apps).addons
        )
        XCTAssertEqual(items, [
            UpdateItem(target: .core, name: "Home Assistant Core", installed: "2026.9.0", latest: "2026.11.1"),
            UpdateItem(target: .operatingSystem, name: "Operating system", installed: "18.2", latest: "18.4"),
            UpdateItem(target: .app(slug: "a0d7b954_tailscale"), name: "Tailscale", installed: "0.29.0", latest: "0.30.0"),
        ])
    }
}

/// Requirement: the client turns guest answers into what the screens show and
/// reports a long operation's real outcome.
@MainActor
final class SupervisorClientTests: XCTestCase {
    /// Answers each command from a script, in order, and records what was sent.
    private final class Script {
        var sent: [String] = []
        var answers: [Result<String, Error>]

        init(_ answers: [Result<String, Error>]) {
            self.answers = answers
        }

        func client() -> SupervisorClient {
            SupervisorClient(send: { [self] command, _ in
                sent.append(command)
                return try answers.removeFirst().get()
            }, pollInterval: .milliseconds(1))
        }
    }

    func testSystemSummaryReadsVersionsDiskAndPendingUpdatesInOneRoundTrip() async throws {
        let answers = [Fixture.info, Fixture.host, Fixture.updates, Fixture.resolution]
        let script = Script([.success(answers.joined(separator: "\n"))])
        let summary = try await script.client().system()
        XCTAssertEqual(script.sent, [GuestCommand.system])
        XCTAssertEqual(summary.info.homeassistant, "2026.9.0")
        XCTAssertEqual(summary.host.diskTotal, 62.3)
        XCTAssertEqual(summary.pending.map(\.updateType), ["core", "os", "addon"])
    }

    /// Requirement: when Home Assistant has marked itself unhealthy it refuses
    /// installs and updates, so the app must know that before the user tries.
    func testSystemSummarySaysWhyHomeAssistantCallsItselfUnhealthy() async throws {
        let answers = [Fixture.info, Fixture.host, Fixture.updates, Fixture.resolution]
        let script = Script([.success(answers.joined(separator: "\n"))])
        let summary = try await script.client().system()
        XCTAssertEqual(summary.unhealthy, ["data_filesystem_check_error"])
    }

    func testSystemSummaryReportsWhyHomeAssistantIsNotReady() async {
        let script = Script([.success(Fixture.notReady)])
        do {
            _ = try await script.client().system()
            XCTFail("an unready system should not produce a summary")
        } catch {
            XCTAssertEqual(error as? SupervisorError, SupervisorError(message: "System is not ready with state: setup"))
        }
    }

    func testLongOperationReportsProgressAndThenSucceeds() async throws {
        let jobs = #"{"result":"ok","data":{"ignore_conditions":[],"jobs":[{"name":"addon_install","reference":"core_mosquitto","uuid":"x","progress":37.5,"stage":null,"done":false,"errors":[],"child_jobs":[]}]}}"#
        let script = Script([
            .success(""),
            .success("running"),
            .success(jobs),
            .success("exit=0\n{\"result\":\"ok\",\"data\":{}}"),
        ])
        var reported: [Double?] = []
        try await script.client().perform("ha apps install core_mosquitto", reference: "core_mosquitto") {
            reported.append($0)
        }
        XCTAssertEqual(reported, [0.375])
        XCTAssertTrue(script.sent[0].hasPrefix("( ( ha apps install core_mosquitto > /tmp/haosrunner-"))
        XCTAssertEqual(script.sent[2], GuestCommand.jobs)
    }

    func testFailedOperationReportsHomeAssistantsReason() async {
        let script = Script([
            .success(""),
            .success("exit=1\n{\"result\":\"error\",\"message\":\"App core_mosquitto is already installed\"}"),
        ])
        do {
            try await script.client().perform("ha apps install core_mosquitto")
            XCTFail("a failed command should throw")
        } catch {
            XCTAssertEqual(
                error as? SupervisorError,
                SupervisorError(message: "App core_mosquitto is already installed")
            )
        }
    }

    func testOperationThatRestartsTheGuestStillFinishes() async throws {
        let script = Script([
            .success(""),
            .failure(GuestShellError.interrupted),
            .failure(GuestShellError.timedOut),
            .success("gone"),
        ])
        try await script.client().perform(GuestCommand.updateOperatingSystem)
        XCTAssertEqual(script.sent.count, 4)
    }

    /// Requirement: a source that has printed nothing shows as an empty log,
    /// which the screen says in words, not as one blank line.
    func testLogWithNoOutputHasNoLines() async throws {
        let empty = try await Script([.success("")]).client().log(.core, lines: 300)
        XCTAssertEqual(empty, [])
        let two = try await Script([.success("first\nsecond")]).client().log(.core, lines: 300)
        XCTAssertEqual(two, ["first", "second"])
    }

    func testOperationStopsWaitingWhenTheMachineIsSwitchedOff() async {
        let script = Script([.success(""), .failure(GuestShellError.unavailable)])
        do {
            try await script.client().perform(GuestCommand.updateCore)
            XCTFail("a stopped machine should end the wait")
        } catch {
            XCTAssertEqual(error as? GuestShellError, .unavailable)
        }
    }
}

/// Requirement: an unhealthy system is explained in words the user can act on.
final class HealthAdviceTests: XCTestCase {
    /// Quitting suspends the machine and the next start resumes the same
    /// running system, failed check included (seen 2026-11-15: three resumes
    /// in a row kept it). Only a restart runs the check again.
    func testInterruptedDiskCheckIsClearedByARestartNotByQuitting() {
        let reasons = ["data_filesystem_check_error"]
        let advice = HealthAdvice.text(for: reasons) ?? ""
        XCTAssertTrue(advice.contains("Restart"), advice)
        XCTAssertTrue(advice.contains("Quitting"), advice)
        XCTAssertTrue(HealthAdvice.restartClears(reasons))
    }

    func testOtherReasonsAreNotOfferedARestart() {
        XCTAssertFalse(HealthAdvice.restartClears(["docker", "privileged"]))
        XCTAssertFalse(HealthAdvice.restartClears(["data_filesystem_check_error", "docker"]))
        XCTAssertFalse(HealthAdvice.restartClears([]))
    }

    func testOtherReasonsAreNamedAndPointToHomeAssistantsRepairs() {
        let advice = HealthAdvice.text(for: ["docker", "privileged"])
        XCTAssertTrue(advice?.contains("docker, privileged") == true, advice ?? "")
        XCTAssertTrue(advice?.contains("Repairs") == true, advice ?? "")
    }

    func testHealthySystemNeedsNoAdvice() {
        XCTAssertNil(HealthAdvice.text(for: []))
    }
}
