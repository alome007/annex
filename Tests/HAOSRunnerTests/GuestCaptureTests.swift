import XCTest
@testable import HAOSRunner

/// Requirement: the app reads answers from the guest over the serial console,
/// one command at a time, and its own traffic stays out of the console the
/// user reads.
@MainActor
final class GuestCaptureTests: XCTestCase {
    private final class Typed {
        var lines: [String] = []
    }

    private func shellAtPrompt() -> (GuestShell, Typed) {
        let typed = Typed()
        let shell = GuestShell { typed.lines.append($0) }
        shell.begin()
        shell.handleTail("# ")
        return (shell, typed)
    }

    private func start(
        _ command: String,
        on shell: GuestShell,
        typed: Typed,
        timeout: TimeInterval = 5
    ) async -> Task<String, Error> {
        let before = typed.lines.count
        let task = Task { try await shell.capture(command, timeout: timeout) }
        while typed.lines.count == before { await Task.yield() }
        return task
    }

    private func commandID(in typedLine: String?) throws -> Int {
        let line = try XCTUnwrap(typedLine)
        let tail = try XCTUnwrap(line.components(separatedBy: "\"END\"-").last)
        return try XCTUnwrap(Int(tail))
    }

    private func answer(_ shell: GuestShell, id: Int, with lines: [String]) {
        _ = shell.handleLine("HAOS-RUNNER-BEGIN-\(id)")
        lines.forEach { _ = shell.handleLine($0) }
        _ = shell.handleLine("HAOS-RUNNER-END-\(id)")
    }

    func testCommandOutputIsReturnedToTheCaller() async throws {
        let (shell, typed) = shellAtPrompt()
        let task = await start("ha apps --raw-json", on: shell, typed: typed)
        let id = try commandID(in: typed.lines.last)

        answer(shell, id: id, with: ["{\"result\":\"ok\"}", "  indented second line"])

        let output = try await task.value
        XCTAssertEqual(output, "{\"result\":\"ok\"}\n  indented second line")
    }

    /// `ha` prints an error answer with no newline after it (seen on HAOS 18.2).
    func testClosingMarkerStartsOnItsOwnLineWhateverTheCommandPrinted() async throws {
        let (shell, typed) = shellAtPrompt()
        let task = await start("ha apps stop missing", on: shell, typed: typed)
        let line = try XCTUnwrap(typed.lines.last)
        XCTAssertTrue(line.contains("ha apps stop missing; echo; echo HAOS-RUNNER-\"END\"-"), line)
        answer(shell, id: try commandID(in: line), with: ["{\"result\":\"error\"}"])
        _ = try await task.value
    }

    func testEchoOfTheTypedCommandNeverEndsTheCapture() async throws {
        let (shell, typed) = shellAtPrompt()
        let task = await start("ha info", on: shell, typed: typed)
        let line = try XCTUnwrap(typed.lines.last)
        let id = try commandID(in: line)

        // The tty echoes what was typed, wrapped at 80 columns.
        _ = shell.handleLine("# " + String(line.prefix(78)))
        _ = shell.handleLine(String(line.dropFirst(78)))
        answer(shell, id: id, with: ["real output"])

        let output = try await task.value
        XCTAssertEqual(output, "real output")
    }

    func testAppTrafficStaysOutOfTheVisibleConsole() async throws {
        let (shell, typed) = shellAtPrompt()
        XCTAssertFalse(shell.handleLine("[  OK  ] Started Docker Application Container Engine"))

        let task = await start("ha info", on: shell, typed: typed)
        let line = try XCTUnwrap(typed.lines.last)
        let id = try commandID(in: line)
        XCTAssertTrue(shell.handleLine("# " + line))
        XCTAssertTrue(shell.handleLine("HAOS-RUNNER-BEGIN-\(id)"))
        XCTAssertTrue(shell.handleLine("output"))
        XCTAssertTrue(shell.handleLine("HAOS-RUNNER-END-\(id)"))
        _ = try await task.value

        XCTAssertFalse(shell.handleLine("a line the guest printed on its own"))
    }

    /// The second command goes out when the first has answered, without waiting
    /// to see a new prompt: a line the guest prints on its own can land on top
    /// of the prompt and hide it, and the queue must not stall on that.
    func testCommandsRunOneAtATimeInOrder() async throws {
        let (shell, typed) = shellAtPrompt()
        let first = await start("one", on: shell, typed: typed)
        let second = Task { try await shell.capture("two", timeout: 5) }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(typed.lines.count, 1)

        answer(shell, id: try commandID(in: typed.lines.last), with: ["1"])
        XCTAssertEqual(typed.lines.count, 2)
        XCTAssertTrue(typed.lines[1].contains("; two; "))
        answer(shell, id: try commandID(in: typed.lines.last), with: ["2"])

        let firstOutput = try await first.value
        let secondOutput = try await second.value
        XCTAssertEqual(firstOutput, "1")
        XCTAssertEqual(secondOutput, "2")
    }

    func testTypingInTheConsoleHoldsAppCommandsUntilThePromptReturns() async throws {
        let (shell, typed) = shellAtPrompt()
        shell.noteUserInput()
        let task = Task { try await shell.capture("ha info", timeout: 5) }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(typed.lines.isEmpty)

        shell.handleTail("# ")
        XCTAssertEqual(typed.lines.count, 1)
        answer(shell, id: try commandID(in: typed.lines.last), with: ["ok"])
        _ = try await task.value
    }

    func testGuestRestartFailsTheCommandInFlightAndLogsInAgain() async throws {
        let (shell, typed) = shellAtPrompt()
        let task = await start("ha os update", on: shell, typed: typed)

        shell.handleTail("homeassistant login: ")

        do {
            _ = try await task.value
            XCTFail("the command should not have completed")
        } catch {
            XCTAssertEqual(error as? GuestShellError, .interrupted)
        }
        XCTAssertEqual(typed.lines.last, "root")
        XCTAssertFalse(shell.isAtShell)

        shell.handleTail("# ")
        XCTAssertTrue(shell.isAtShell)
    }

    func testUnansweredCommandTimesOut() async throws {
        let (shell, typed) = shellAtPrompt()
        let task = await start("ha info", on: shell, typed: typed, timeout: 0.05)
        do {
            _ = try await task.value
            XCTFail("the command should have timed out")
        } catch {
            XCTAssertEqual(error as? GuestShellError, .timedOut)
        }
    }

    func testCommandFailsAtOnceWhileTheMachineIsOff() async {
        let shell = GuestShell { _ in }
        do {
            _ = try await shell.capture("ha info")
            XCTFail("the command should have failed")
        } catch {
            XCTAssertEqual(error as? GuestShellError, .unavailable)
        }
    }

    func testStoppingTheMachineFailsWaitingCommands() async throws {
        let (shell, typed) = shellAtPrompt()
        let task = await start("ha info", on: shell, typed: typed)
        shell.reset()
        do {
            _ = try await task.value
            XCTFail("the command should have failed")
        } catch {
            XCTAssertEqual(error as? GuestShellError, .unavailable)
        }
    }
}

/// Requirement: guest output arrives in arbitrary chunks and none of it may be
/// lost, because one damaged character breaks a whole JSON answer.
final class LineAssemblerTests: XCTestCase {
    func testCharacterSplitAcrossTwoReadsSurvives() {
        let bytes = Array("{\"name\":\"Café\"}\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1
        var assembler = LineAssembler()

        let first = assembler.ingest(Data(bytes[..<split]))
        let second = assembler.ingest(Data(bytes[split...]))

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, ["{\"name\":\"Café\"}"])
        XCTAssertEqual(assembler.tail, "")
    }

    func testUnfinishedLineIsKeptAsTheTail() {
        var assembler = LineAssembler()
        let lines = assembler.ingest(Data("booted\nhomeassistant login: ".utf8))
        XCTAssertEqual(lines, ["booted"])
        XCTAssertEqual(assembler.tail, "homeassistant login: ")
    }
}
