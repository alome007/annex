import XCTest
@testable import HAOSRunner

final class GuestDNSTests: XCTestCase {
    func testProbeReportsAStatusCodeSoTheEchoedCommandCannotBeMistakenForTheResult() {
        let command = GuestNetwork.dnsProbeCommand
        XCTAssertTrue(command.contains("haosdns=%{http_code}"))
        XCTAssertNil(GuestNetwork.dnsProbeResult(in: "> " + command))
        XCTAssertNil(GuestNetwork.dnsProbeResult(in: "# " + command))
    }

    /// curl writes no `-w` output when it cannot resolve the host, so without an
    /// explicit fallback the probe would stay silent in the one case it exists
    /// to catch, and the override would never fire.
    func testProbeStillReportsWhenResolutionFailsOutright() {
        let command = GuestNetwork.dnsProbeCommand
        XCTAssertTrue(command.contains("|| printf 'haosdns=%s\\n' 000"))
        XCTAssertNil(GuestNetwork.dnsProbeResult(in: "> " + command), "the fallback must not match its own echo")
        XCTAssertEqual(GuestNetwork.dnsProbeResult(in: "haosdns=000"), 0)
    }

    func testReadsTheStatusFromProbeOutput() {
        XCTAssertEqual(GuestNetwork.dnsProbeResult(in: "haosdns=200"), 200)
        XCTAssertEqual(GuestNetwork.dnsProbeResult(in: "haosdns=000"), 0)
        XCTAssertEqual(GuestNetwork.dnsProbeResult(in: "some noise haosdns=301 trailing"), 301)
    }

    func testIgnoresUnrelatedLines() {
        XCTAssertNil(GuestNetwork.dnsProbeResult(in: "Supervisor is up and running"))
        XCTAssertNil(GuestNetwork.dnsProbeResult(in: "haosdns="))
    }

    func testOnlyTwoHundredCountsAsWorkingDNS() {
        XCTAssertTrue(GuestNetwork.dnsIsWorking(probeStatus: 200))
        XCTAssertFalse(GuestNetwork.dnsIsWorking(probeStatus: 0))
        XCTAssertFalse(GuestNetwork.dnsIsWorking(probeStatus: 503))
    }

    func testOverrideUsesPlainResolversWithASingleServerFallback() {
        let command = GuestNetwork.publicResolverCommand
        XCTAssertTrue(command.contains("ha dns options --servers dns://1.1.1.1 --servers dns://8.8.8.8"))
        XCTAssertTrue(command.contains("|| docker exec hassio_cli ha dns options --servers dns://8.8.8.8"))
    }

    func testOverrideNeverRestartsSupervisor() {
        XCTAssertFalse(GuestNetwork.publicResolverCommand.contains("restart hassio_supervisor"))
        XCTAssertFalse(GuestNetwork.publicResolverCommand.contains("supervisor reload"))
    }
}
