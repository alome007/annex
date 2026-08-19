import XCTest
@testable import HAOSRunner

/// The bridge is load-bearing: Home Assistant rejects network-origin WebSockets,
/// so onboarding fails when the browser talks to Core directly even though every
/// HTTP request and the upgrade handshake succeed. These tests exist so the
/// forwarding target cannot be changed or removed unnoticed.
final class RelayBridgeTests: XCTestCase {
    func testForwardsLoopbackToTheDetectedCorePort() {
        let command = RelayInstall.command(corePort: 8123)
        XCTAssertTrue(command.contains("TCP-LISTEN:9999,fork,reuseaddr TCP:127.0.0.1:8123"))
    }

    func testForwardsToPortEightyWhenCoreServesThere() {
        XCTAssertTrue(RelayInstall.command(corePort: 80).contains("TCP:127.0.0.1:80"))
    }

    func testSurvivesGuestRebootsAndReplacesAnyOldContainer() {
        let command = RelayInstall.command(corePort: 80)
        XCTAssertTrue(command.contains("--restart unless-stopped"))
        XCTAssertTrue(command.contains("docker rm -f harelay"))
        XCTAssertTrue(command.contains("--network host"))
    }

    func testRetriesTheImagePullBecauseDockerHubThrottles() {
        XCTAssertTrue(RelayInstall.command(corePort: 80).contains("for i in 1 2 3 4 5"))
    }

    func testListensOnTheAdvertisedPort() {
        XCTAssertEqual(RelayInstall.port, 9999)
    }

    func testBridgeStageIsTheLastBootStage() {
        XCTAssertEqual(BootStage.connectingBridge.ordinal, 5)
        XCTAssertEqual(BootStage.connectingBridge.title, "Connecting the bridge")
    }
}
