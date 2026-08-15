import XCTest
@testable import HAOSRunner

final class MACAddressTests: XCTestCase {
    func testNormalizesZeroPaddedToCanonical() {
        XCTAssertEqual(MACAddress.normalized("A6:BA:FD:24:ED:6D"), "a6:ba:fd:24:ed:6d")
        XCTAssertEqual(MACAddress.normalized("d6:0e:84:49:a7:bd"), "d6:e:84:49:a7:bd")
    }

    func testNormalizesUnpaddedForm() {
        XCTAssertEqual(MACAddress.normalized("d6:e:84:49:a7:bd"), "d6:e:84:49:a7:bd")
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(MACAddress.normalized(""))
        XCTAssertNil(MACAddress.normalized("a6:ba:fd:24:ed"))
        XCTAssertNil(MACAddress.normalized("zz:ba:fd:24:ed:6d"))
        XCTAssertNil(MACAddress.normalized("(incomplete)"))
    }
}

final class DHCPLeasesTests: XCTestCase {
    private let fileText = """
    {
    \tname=homeassistant
    \tip_address=192.168.64.17
    \thw_address=1,a6:ba:fd:24:ed:6d
    \tidentifier=1,a6:ba:fd:24:ed:6d
    \tlease=0x6a7e2344
    }
    {
    \tname=homeassistant
    \tip_address=192.168.64.15
    \thw_address=1,d6:e:84:49:a7:bd
    \tidentifier=1,d6:e:84:49:a7:bd
    \tlease=0x6a7a280c
    }
    """

    func testFindsAddressForPaddedMAC() {
        XCTAssertEqual(DHCPLeases.ipAddress(forMAC: "a6:ba:fd:24:ed:6d", in: fileText), "192.168.64.17")
    }

    func testMatchesUnpaddedLeaseAgainstPaddedMAC() {
        XCTAssertEqual(DHCPLeases.ipAddress(forMAC: "d6:0e:84:49:a7:bd", in: fileText), "192.168.64.15")
    }

    func testReturnsNilForUnknownMAC() {
        XCTAssertNil(DHCPLeases.ipAddress(forMAC: "aa:bb:cc:dd:ee:ff", in: fileText))
    }

    func testReturnsNilForEmptyFile() {
        XCTAssertNil(DHCPLeases.ipAddress(forMAC: "a6:ba:fd:24:ed:6d", in: ""))
    }
}

final class ARPTableTests: XCTestCase {
    private let tableText = """
    ? (192.168.64.1) at be:d0:74:37:f5:64 on bridge100 ifscope permanent [bridge]
    ? (192.168.64.17) at a6:ba:fd:24:ed:6d on bridge100 ifscope [bridge]
    ? (192.168.100.10) at (incomplete) on en0 ifscope [ethernet]
    ? (192.168.100.102) at 66:2a:9a:d:8e:2e on en0 ifscope [ethernet]
    """

    func testFindsAddressForMAC() {
        XCTAssertEqual(ARPTable.ipAddress(forMAC: "a6:ba:fd:24:ed:6d", in: tableText), "192.168.64.17")
    }

    func testMatchesUnpaddedEntryAgainstPaddedMAC() {
        XCTAssertEqual(ARPTable.ipAddress(forMAC: "66:2a:9a:0d:8e:2e", in: tableText), "192.168.100.102")
    }

    func testIgnoresIncompleteEntries() {
        XCTAssertNil(ARPTable.ipAddress(forMAC: "aa:bb:cc:dd:ee:ff", in: tableText))
    }
}

final class GuestPromptTests: XCTestCase {
    func testClassifiesGettyLoginPrompt() {
        XCTAssertEqual(GuestPrompt.classify(tail: "homeassistant login: "), .gettyLogin)
        XCTAssertEqual(GuestPrompt.classify(tail: "homeassistant login:"), .gettyLogin)
        XCTAssertEqual(GuestPrompt.classify(tail: "Welcome to Home Assistant\nhomeassistant Login: "), .gettyLogin)
    }

    func testClassifiesHomeAssistantCLIPrompt() {
        XCTAssertEqual(GuestPrompt.classify(tail: "ha > "), .haCLI)
        XCTAssertEqual(GuestPrompt.classify(tail: "Welcome to the Home Assistant command line.\nha >"), .haCLI)
    }

    func testClassifiesRootShellPrompt() {
        XCTAssertEqual(GuestPrompt.classify(tail: "# "), .rootShell)
        XCTAssertEqual(GuestPrompt.classify(tail: "haos-runner:~# "), .rootShell)
    }

    func testUnrecognisedTailIsNil() {
        XCTAssertNil(GuestPrompt.classify(tail: ""))
        XCTAssertNil(GuestPrompt.classify(tail: "Downloading 42%"))
        XCTAssertNil(GuestPrompt.classify(tail: "[  OK  ] Started Docker Application Container Engine"))
    }
}

final class SupervisorLogTests: XCTestCase {
    func testParsesDownloadPercent() {
        let line = "24-01-11 09:12:33 INFO (SyncWorker_0) [supervisor.docker.interface] Downloading Home Assistant Core image ghcr.io/home-assistant/qemuarm-64-homeassistant with tag 2026.8.1, 42%"
        XCTAssertEqual(SupervisorLog.downloadPercent(in: line), 42)
    }

    func testIgnoresUnrelatedLinesWithPercents() {
        XCTAssertNil(SupervisorLog.downloadPercent(in: "CPU usage at 42%"))
        XCTAssertNil(SupervisorLog.downloadPercent(in: "Downloading Home Assistant Core image"))
    }

    func testRejectsOutOfRangeValues() {
        XCTAssertNil(SupervisorLog.downloadPercent(in: "Downloading Home Assistant Core image, 400%"))
    }
}

final class ConsoleTextTests: XCTestCase {
    func testStripsCSISequences() {
        XCTAssertEqual(ConsoleText.strippedOfControlSequences("\u{1B}[32mOK\u{1B}[0m"), "OK")
        XCTAssertEqual(ConsoleText.strippedOfControlSequences("\u{1B}[2J\u{1B}[Hboot"), "boot")
    }

    func testStripsOSCSequencesTerminatedByBEL() {
        XCTAssertEqual(ConsoleText.strippedOfControlSequences("\u{1B}]0;window title\u{07}# "), "# ")
    }

    func testDropsCarriageReturns() {
        XCTAssertEqual(ConsoleText.strippedOfControlSequences("progress\rdone"), "progressdone")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(ConsoleText.strippedOfControlSequences("homeassistant login: "), "homeassistant login: ")
    }
}
