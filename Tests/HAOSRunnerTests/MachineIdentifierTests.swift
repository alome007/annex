import Virtualization
import XCTest
@testable import HAOSRunner

/// Requirement: a session suspended at quit can be restored on the next launch.
/// Virtualization only restores into a configuration carrying the identifier
/// the machine was saved with, so the identifier has to outlive the process.
final class MachineIdentifierTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "haosrunner-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testIdentifierIsTheSameOnEveryRequest() {
        XCTAssertEqual(
            StableMachineIdentifier.identifier(in: defaults),
            StableMachineIdentifier.identifier(in: defaults)
        )
    }

    func testIdentifierIsStoredSoTheNextLaunchReadsTheSameOne() throws {
        let first = StableMachineIdentifier.identifier(in: defaults)
        let nextLaunch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(StableMachineIdentifier.identifier(in: nextLaunch), first)
    }

    func testSeparateMachinesGetSeparateIdentifiers() throws {
        let otherSuite = "haosrunner-tests-\(UUID().uuidString)"
        let other = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { other.removePersistentDomain(forName: otherSuite) }
        XCTAssertNotEqual(
            StableMachineIdentifier.identifier(in: defaults),
            StableMachineIdentifier.identifier(in: other)
        )
    }
}
