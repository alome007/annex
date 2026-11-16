import Foundation
import os

/// Home Assistant serves its WebSocket cleanly to loopback-origin requests but
/// rejects ones arriving over the network, and `:8123` answers a WebSocket
/// upgrade with a redirect that browsers cannot follow. Onboarding and the live
/// dashboard therefore fail when the browser talks to Core directly, even
/// though every HTTP request and the upgrade handshake itself succeed. That
/// is why testing those two things is not enough to conclude the bridge is
/// unnecessary. A `socat` container in the guest's own network namespace
/// forwards `:9999` to Core over loopback, so Home Assistant sees every
/// connection as local. Verified on 2026-08-19: onboarding fails without this
/// and completes with it. Do not remove.
enum RelayInstall {
    static let port = 9999
    static let containerName = "harelay"

    static func command(corePort: Int) -> String {
        "for i in 1 2 3 4 5; do docker pull alpine/socat && break; sleep 6; done; "
            + "docker rm -f \(containerName) 2>/dev/null; "
            + "docker run -d --network host --restart unless-stopped --name \(containerName) "
            + "alpine/socat TCP-LISTEN:\(port),fork,reuseaddr TCP:127.0.0.1:\(corePort)"
    }
}

enum SupervisorProbe {
    /// Supervisor's newest log line, whatever it says. It logs a download once
    /// when it starts and then stays silent until it ends, so the last line is
    /// the only reliable account of what a long wait is waiting for.
    static let progressCommand = "docker logs --tail 1 hassio_supervisor 2>&1"
}

/// Why a command sent to the guest produced no answer.
enum GuestShellError: LocalizedError, Equatable {
    case unavailable
    case timedOut
    case interrupted

    var errorDescription: String? {
        switch self {
        case .unavailable: "Home Assistant is not running."
        case .timedOut: "The machine did not answer in time."
        case .interrupted: "The machine restarted before it answered."
        }
    }
}

/// Runs commands in the guest's root shell over the serial console.
///
/// The console is one shared terminal, so commands go out one at a time, and
/// never while something the user typed may still be running. Each is wrapped
/// in a pair of marker lines; what the guest prints between them is the
/// command's output.
@MainActor
final class GuestShell {
    enum Stage: Equatable {
        case idle
        case seekingPrompt
        case sentRoot
        case sentLogin
        case atShell
    }

    private struct Request {
        let id: Int
        let command: String
        let completion: (Result<String, GuestShellError>) -> Void
        var output: [String] = []
        var began = false
    }

    private(set) var stage: Stage = .idle

    private let type: (String) -> Void
    private let log = Logger(subsystem: "casa.astrohome.haosrunner", category: "shell")
    private var lastActionAt = Date.distantPast
    private var nudge: Timer?
    private var pending: [Request] = []
    private var inFlight: Request?
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextCommandID = 1
    private var promptShowing = false

    /// - Parameter type: sends one line of text to the guest's terminal.
    init(type: @escaping (String) -> Void) {
        self.type = type
    }

    var isAtShell: Bool { stage == .atShell }

    /// Whether a command sent now would run straight away.
    var isIdle: Bool { stage == .atShell && inFlight == nil && pending.isEmpty }

    func begin() {
        guard stage == .idle else { return }
        stage = .seekingPrompt
        lastActionAt = .now
        nudge = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.nudgeIfStalled() }
        }
    }

    /// Asks the guest to print its prompt again. A machine resumed from a
    /// suspended session is already sitting at one and prints nothing new.
    func requestPrompt() {
        guard stage != .idle, stage != .atShell else { return }
        lastActionAt = .now
        type("")
    }

    func reset() {
        nudge?.invalidate()
        nudge = nil
        stage = .idle
        promptShowing = false
        failAll(.unavailable)
    }

    /// Runs a command whose output nobody reads.
    func run(_ command: String, timeout: TimeInterval = 900) {
        enqueue(command, timeout: timeout) { _ in }
    }

    /// Runs a command and returns what it printed.
    func capture(_ command: String, timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(command, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    /// Records that the user typed into the console, so the app waits for the
    /// prompt to come back instead of typing into whatever they started.
    func noteUserInput() {
        promptShowing = false
    }

    func handleTail(_ tail: String) {
        guard stage != .idle else { return }
        guard let prompt = GuestPrompt.classify(tail: tail) else { return }
        // Half a line of command output can end like a login prompt. A restart
        // in the middle of an answer is caught when that answer times out.
        if inFlight?.began == true, prompt != .rootShell { return }
        switch prompt {
        case .gettyLogin:
            leaveShell()
            attempt(.sentRoot) { type("root") }
        case .haCLI:
            leaveShell()
            attempt(.sentLogin) { type("login") }
        case .rootShell:
            reachShell()
        }
    }

    /// Feeds one console line through the command protocol.
    ///
    /// - Returns: true when the line belongs to a command the app sent, which
    ///   keeps it out of the console the user reads.
    func handleLine(_ line: String) -> Bool {
        guard var request = inFlight else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !request.began {
            // Everything before the opening marker is the terminal echoing the
            // typed command back.
            if trimmed == Self.marker("BEGIN", request.id) {
                request.began = true
                inFlight = request
            }
            return true
        }
        if trimmed == Self.marker("END", request.id) {
            // The command is over, so the shell is reading again. Waiting to
            // see its prompt would stall the queue whenever a line the guest
            // prints on its own lands on top of it.
            promptShowing = true
            finish(.success(request.output.joined(separator: "\n")))
            return true
        }
        request.output.append(line)
        inFlight = request
        return true
    }

    private static func marker(_ edge: String, _ id: Int) -> String {
        "HAOS-RUNNER-\(edge)-\(id)"
    }

    /// The text typed for a request. The quotes vanish when the shell runs the
    /// `echo`, so the echoed command line can never equal a marker, however the
    /// terminal wraps it. The bare `echo` before the closing marker starts a
    /// new line: `ha` prints an error answer without one, which would leave
    /// the marker glued to the end of the answer.
    private static func typedText(for request: Request) -> String {
        "echo HAOS-RUNNER-\"BEGIN\"-\(request.id); \(request.command); echo; echo HAOS-RUNNER-\"END\"-\(request.id)"
    }

    private func enqueue(
        _ command: String,
        timeout: TimeInterval,
        completion: @escaping (Result<String, GuestShellError>) -> Void
    ) {
        guard stage != .idle else {
            completion(.failure(.unavailable))
            return
        }
        let id = nextCommandID
        nextCommandID += 1
        pending.append(Request(id: id, command: command, completion: completion))
        deadlines[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
        sendNextIfReady()
    }

    private func sendNextIfReady() {
        guard stage == .atShell, promptShowing, inFlight == nil, let next = pending.first else { return }
        pending.removeFirst()
        inFlight = next
        promptShowing = false
        type(Self.typedText(for: next))
    }

    private func finish(_ result: Result<String, GuestShellError>) {
        guard let request = inFlight else { return }
        inFlight = nil
        deadlines.removeValue(forKey: request.id)?.cancel()
        request.completion(result)
        sendNextIfReady()
    }

    private func expire(_ id: Int) {
        if let request = inFlight, request.id == id {
            log.error("guest command timed out: \(request.command, privacy: .public)")
            // Control-C, so a command that is still running gives the shell back.
            if request.began {
                type("\u{03}")
                promptShowing = true
            }
            finish(.failure(.timedOut))
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            let request = pending.remove(at: index)
            deadlines.removeValue(forKey: id)
            request.completion(.failure(.timedOut))
        }
    }

    private func failAll(_ error: GuestShellError) {
        let waiting = [inFlight].compactMap { $0 } + pending
        inFlight = nil
        pending = []
        deadlines.values.forEach { $0.cancel() }
        deadlines = [:]
        waiting.forEach { $0.completion(.failure(error)) }
    }

    /// A login prompt while the app believed it was in the shell means the
    /// guest restarted, so whatever was running is gone.
    private func leaveShell() {
        guard stage == .atShell else { return }
        log.notice("guest shell lost; logging in again")
        stage = .seekingPrompt
        promptShowing = false
        lastActionAt = .distantPast
        if inFlight != nil { finish(.failure(.interrupted)) }
    }

    private func attempt(_ target: Stage, action: () -> Void) {
        guard stage != .atShell else { return }
        if stage == target, Date.now.timeIntervalSince(lastActionAt) < 10 { return }
        lastActionAt = .now
        stage = target
        action()
    }

    private func reachShell() {
        lastActionAt = .now
        promptShowing = true
        if stage != .atShell {
            stage = .atShell
            log.notice("guest shell ready")
        }
        sendNextIfReady()
    }

    private func nudgeIfStalled() {
        guard stage != .idle, stage != .atShell else { return }
        guard Date.now.timeIntervalSince(lastActionAt) > 8 else { return }
        type("")
    }
}
