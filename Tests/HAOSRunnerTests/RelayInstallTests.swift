import XCTest
@testable import HAOSRunner

final class RelayInstallTests: XCTestCase {
    func testForwardsToTheDetectedCorePort() {
        let command = RelayInstall.command(corePort: 8123)
        XCTAssertTrue(command.contains("TCP-LISTEN:9999,fork,reuseaddr TCP:127.0.0.1:8123"))
        XCTAssertTrue(command.contains("--restart unless-stopped"))
        XCTAssertTrue(command.contains("--network host"))
    }

    func testStillSupportsCoreServedOnPort80() {
        XCTAssertTrue(RelayInstall.command(corePort: 80).contains("TCP:127.0.0.1:80"))
    }

    func testReplacesAnyExistingRelayContainer() {
        XCTAssertTrue(RelayInstall.command(corePort: 8123).contains("docker rm -f harelay"))
    }

    func testProgressPollWatchesProgressAndConnectivity() {
        let command = RelayInstall.supervisorProgressCommand
        XCTAssertTrue(command.contains("Core image"))
        XCTAssertTrue(command.contains("no supervisor internet connection"))
        XCTAssertTrue(command.contains("--since 2m"))
    }

    func testProbesCoreOwnPortBeforeTheRedirectingPort() {
        XCTAssertEqual(HTTPProbe.corePorts, [8123, 80])
    }
}
