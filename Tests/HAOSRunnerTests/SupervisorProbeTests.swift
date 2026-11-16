import XCTest
@testable import HAOSRunner

final class SupervisorProbeTests: XCTestCase {
    /// Requirement: the poll reads Supervisor's newest log line whatever it
    /// says. A download is logged once when it starts and can run far longer
    /// than any time window, and a filter would hide whatever came after it.
    func testProgressPollReadsSupervisorsLatestLine() {
        let command = SupervisorProbe.progressCommand
        XCTAssertTrue(command.contains("docker logs --tail 1 hassio_supervisor"))
        XCTAssertTrue(command.contains("2>&1"), "Supervisor logs to stderr")
        XCTAssertFalse(command.contains("--since"))
        XCTAssertFalse(command.contains("grep"))
    }

    func testDetectsEveryConnectivityWordingSupervisorUses() {
        XCTAssertTrue(SupervisorLog.reportsNoInternet(
            "INFO (MainThread) [supervisor.updater] No Supervisor connectivity, delaying version fetch"
        ))
        XCTAssertTrue(SupervisorLog.reportsNoInternet(
            "WARNING [supervisor.jobs] blocked from execution, no supervisor internet connection"
        ))
    }

    func testProbesCoreOwnPortBeforeTheRedirectingPort() {
        XCTAssertEqual(HTTPProbe.corePorts, [8123, 80])
    }
}
