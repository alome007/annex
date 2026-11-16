import XCTest
@testable import HAOSRunner

/// Requirement: the app reports only what Supervisor itself logged. The guest
/// console echoes every command the app types, and an echoed command can
/// contain the very phrases the app looks for.
final class SupervisorRecordTests: XCTestCase {
    /// The echo of the progress poll exactly as the guest console wrapped it at
    /// 80 columns. The second fragment carries every phrase the poll searched
    /// for, which is what made each start report a connection problem.
    private let echoedPoll = [
        "# docker logs --since 2m hassio_supervisor 2>/dev/null | grep -iE 'core image|su",
        "pervisor connectivity|no supervisor internet|has no home assistant version' | ta",
        "il -n 2",
    ]

    func testEchoedCommandIsNotAConnectivityReport() {
        for fragment in echoedPoll {
            XCTAssertFalse(SupervisorLog.reportsNoInternet(fragment), fragment)
        }
    }

    func testEchoedCommandIsNotADownload() {
        XCTAssertNil(SupervisorLog.download(
            in: "# docker logs hassio_supervisor | grep 'Downloading docker image x with tag 1.0'"
        ))
    }

    func testThePollCommandCannotBeReadBackAsARecord() {
        XCTAssertFalse(SupervisorLog.isRecord(SupervisorProbe.progressCommand))
        XCTAssertFalse(SupervisorLog.isRecord("> " + SupervisorProbe.progressCommand))
    }

    func testConnectivityReportsFromSupervisorStillCount() {
        XCTAssertTrue(SupervisorLog.reportsNoInternet(
            "2026-11-14 20:13:04.576+01:00 INFO (MainThread) [supervisor.updater] No Supervisor connectivity, delaying version fetch"
        ))
    }
}

/// Requirement: while Supervisor is downloading an update, the app can say
/// which component and version, so a long wait is not mistaken for a hang.
final class SupervisorDownloadTests: XCTestCase {
    private func record(_ message: String) -> String {
        "2026-11-14 19:53:43.309 INFO (MainThread) [supervisor.docker.interface] " + message
    }

    func testReadsSupervisorSelfUpdate() {
        let line = record("Downloading docker image ghcr.io/home-assistant/aarch64-hassio-supervisor with tag 2026.11.0.")
        XCTAssertEqual(
            SupervisorLog.download(in: line),
            SupervisorLog.Download(component: "supervisor", version: "2026.11.0")
        )
    }

    func testReadsPluginUpdate() {
        let line = record("Downloading docker image ghcr.io/home-assistant/aarch64-hassio-cli with tag 2026.10.1.")
        XCTAssertEqual(
            SupervisorLog.download(in: line),
            SupervisorLog.Download(component: "cli", version: "2026.10.1")
        )
    }

    func testReadsCoreInstall() {
        let line = record("Downloading docker image ghcr.io/home-assistant/qemuarm-64-homeassistant with tag 2026.9.0.")
        XCTAssertEqual(
            SupervisorLog.download(in: line),
            SupervisorLog.Download(component: "homeassistant", version: "2026.9.0")
        )
    }

    func testOtherRecordsAreNotDownloads() {
        XCTAssertNil(SupervisorLog.download(
            in: record("Updating image ghcr.io/home-assistant/aarch64-hassio-cli:2026.09.0 to ghcr.io/home-assistant/aarch64-hassio-cli:2026.10.1")
        ))
        XCTAssertNil(SupervisorLog.download(
            in: "2026-11-14 20:13:04.576+01:00 INFO (MainThread) [supervisor.plugins.manager] Plugin cli is not up-to-date, latest version 2026.10.1, updating"
        ))
    }
}
