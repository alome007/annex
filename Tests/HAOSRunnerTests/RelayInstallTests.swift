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
}

final class CoreProbeTests: XCTestCase {
    func testAcceptsUnauthorizedAndOKAsCoreUp() {
        XCTAssertTrue(HTTPProbe.coreAnswers(status: 200))
        XCTAssertTrue(HTTPProbe.coreAnswers(status: 401))
    }

    func testRejectsRedirectsAndErrors() {
        XCTAssertFalse(HTTPProbe.coreAnswers(status: 302))
        XCTAssertFalse(HTTPProbe.coreAnswers(status: 404))
        XCTAssertFalse(HTTPProbe.coreAnswers(status: 502))
        XCTAssertFalse(HTTPProbe.coreAnswers(status: nil))
    }

    func testPrefersCoreOwnPortOverTheRedirectingPort() {
        XCTAssertEqual(HTTPProbe.corePorts.first, 8123)
        XCTAssertEqual(HTTPProbe.corePorts, [8123, 80])
    }
}
