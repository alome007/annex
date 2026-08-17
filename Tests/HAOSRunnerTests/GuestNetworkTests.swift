import XCTest
@testable import HAOSRunner

final class GuestNetworkTests: XCTestCase {
    func testDerivesGatewayFromGuestAddress() {
        XCTAssertEqual(GuestNetwork.gatewayAddress(forGuestIP: "192.168.64.21"), "192.168.64.1")
        XCTAssertEqual(GuestNetwork.gatewayAddress(forGuestIP: "192.168.65.2"), "192.168.65.1")
    }

    func testRejectsMalformedAddresses() {
        XCTAssertNil(GuestNetwork.gatewayAddress(forGuestIP: "192.168.64"))
        XCTAssertNil(GuestNetwork.gatewayAddress(forGuestIP: "not.an.ip.addr"))
        XCTAssertNil(GuestNetwork.gatewayAddress(forGuestIP: "999.1.1.1"))
    }

    func testRepairCommandPointsResolverAtGatewayAndRestartsServices() {
        let command = GuestNetwork.repairCommand(gateway: "192.168.64.1")
        XCTAssertTrue(command.contains("ha dns options --servers dns://192.168.64.1"))
        XCTAssertTrue(command.contains("docker restart hassio_dns"))
        XCTAssertTrue(command.contains("docker restart hassio_supervisor"))
    }

    func testRepairSurvivesAStoppedCLIContainer() {
        let command = GuestNetwork.repairCommand(gateway: "192.168.64.1")
        XCTAssertTrue(command.contains("docker start hassio_cli"))
        XCTAssertTrue(command.contains("|| true"))
    }

    func testNudgeFallsBackToRestartingSupervisorWithoutTheCLI() {
        let command = GuestNetwork.nudgeCommand
        XCTAssertTrue(command.contains("ha supervisor reload"))
        XCTAssertTrue(command.contains("|| docker restart hassio_supervisor"))
    }
}

final class SupervisorConnectivityTests: XCTestCase {
    func testDetectsNoInternetReports() {
        XCTAssertTrue(SupervisorLog.reportsNoInternet(
            "WARNING (MainThread) [supervisor.jobs] 'GitRepo.clone' blocked from execution, no supervisor internet connection"
        ))
        XCTAssertTrue(SupervisorLog.reportsNoInternet(
            "INFO (MainThread) [supervisor.updater] No Supervisor connectivity, delaying version fetch"
        ))
        XCTAssertTrue(SupervisorLog.reportsNoInternet(
            "WARNING [supervisor.homeassistant.core] Updater has no Home Assistant version information yet. Retrying in 30sec"
        ))
    }

    func testIgnoresHealthyLines() {
        XCTAssertFalse(SupervisorLog.reportsNoInternet("INFO [supervisor.core] Supervisor is up and running"))
        XCTAssertFalse(SupervisorLog.reportsNoInternet(
            "INFO [supervisor.homeassistant.core] Home Assistant Core installation in progress"
        ))
    }
}

final class CoreVersusLandingPageTests: XCTestCase {
    func testLandingPageIsNotMistakenForCore() {
        XCTAssertFalse(HTTPProbe.coreAnswers(onboardingStatus: 401, manifestStatus: 404))
    }

    func testCoreBeforeOnboardingIsDetected() {
        XCTAssertTrue(HTTPProbe.coreAnswers(onboardingStatus: 200, manifestStatus: 200))
    }

    func testCoreAfterOnboardingIsDetected() {
        XCTAssertTrue(HTTPProbe.coreAnswers(onboardingStatus: 404, manifestStatus: 200))
    }

    func testManifestAloneIsEnough() {
        XCTAssertTrue(HTTPProbe.coreAnswers(onboardingStatus: 401, manifestStatus: 200))
    }

    func testNothingAnsweringIsNotCore() {
        XCTAssertFalse(HTTPProbe.coreAnswers(onboardingStatus: nil, manifestStatus: nil))
    }
}
