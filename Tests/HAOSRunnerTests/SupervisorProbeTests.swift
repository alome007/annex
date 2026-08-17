import XCTest
@testable import HAOSRunner

final class SupervisorProbeTests: XCTestCase {
    func testProgressPollWatchesProgressAndConnectivityCaseInsensitively() {
        let command = SupervisorProbe.progressCommand
        XCTAssertTrue(command.contains("grep -iE"))
        XCTAssertTrue(command.contains("core image"))
        XCTAssertTrue(command.contains("supervisor connectivity"))
        XCTAssertTrue(command.contains("no supervisor internet"))
        XCTAssertTrue(command.contains("--since 2m"))
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
