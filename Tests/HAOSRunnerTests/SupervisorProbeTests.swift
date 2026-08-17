import XCTest
@testable import HAOSRunner

final class SupervisorProbeTests: XCTestCase {
    func testProgressPollWatchesProgressAndConnectivity() {
        let command = SupervisorProbe.progressCommand
        XCTAssertTrue(command.contains("Core image"))
        XCTAssertTrue(command.contains("no supervisor internet connection"))
        XCTAssertTrue(command.contains("--since 2m"))
    }

    func testProbesCoreOwnPortBeforeTheRedirectingPort() {
        XCTAssertEqual(HTTPProbe.corePorts, [8123, 80])
    }
}
