import XCTest
@testable import HAOSRunner

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
