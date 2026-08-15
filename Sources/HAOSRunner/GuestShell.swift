import Foundation
import os

enum RelayInstall {
    static let port = 9999
    static let containerName = "harelay"

    static var command: String {
        "for i in 1 2 3 4 5; do docker pull alpine/socat && break; sleep 6; done; "
            + "docker rm -f \(containerName) 2>/dev/null; "
            + "docker run -d --network host --restart unless-stopped --name \(containerName) "
            + "alpine/socat TCP-LISTEN:\(port),fork,reuseaddr TCP:127.0.0.1:80"
    }

    static let supervisorProgressCommand =
        "docker logs --since 2m hassio_supervisor 2>/dev/null | grep 'Core image' | tail -n 1"
}

@MainActor
final class GuestShell {
    enum Stage: Equatable {
        case idle
        case seekingPrompt
        case sentRoot
        case sentLogin
        case atShell
    }

    private struct QueuedCommand {
        let id: Int
        let command: String
        let completion: (() -> Void)?
    }

    private(set) var stage: Stage = .idle

    private let console: SerialConsole
    private let log = Logger(subsystem: "casa.astrohome.haosrunner", category: "shell")
    private var lastActionAt = Date.distantPast
    private var nudge: Timer?
    private var pending: [QueuedCommand] = []
    private var inFlight: QueuedCommand?
    private var nextCommandID = 1

    init(console: SerialConsole) {
        self.console = console
    }

    var isAtShell: Bool { stage == .atShell }

    func begin() {
        guard stage == .idle else { return }
        stage = .seekingPrompt
        lastActionAt = .now
        nudge = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.nudgeIfStalled() }
        }
    }

    func reset() {
        nudge?.invalidate()
        nudge = nil
        stage = .idle
        pending = []
        inFlight = nil
    }

    func run(_ command: String, completion: (() -> Void)? = nil) {
        pending.append(QueuedCommand(id: nextCommandID, command: command, completion: completion))
        nextCommandID += 1
        begin()
        sendNextIfReady()
    }

    func handleTail(_ tail: String) {
        guard stage != .idle else { return }
        guard let prompt = GuestPrompt.classify(tail: tail) else { return }
        switch prompt {
        case .gettyLogin:
            attempt(.sentRoot) { console.send("root") }
        case .haCLI:
            attempt(.sentLogin) { console.send("login") }
        case .rootShell:
            reachShell()
        }
    }

    func handleLine(_ line: String) {
        guard let current = inFlight else { return }
        guard line.trimmingCharacters(in: .whitespaces) == Self.sentinel(for: current.id) else { return }
        inFlight = nil
        current.completion?()
        sendNextIfReady()
    }

    private static func sentinel(for id: Int) -> String {
        "HAOS-RUNNER-DONE-\(id)"
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
        if stage != .atShell {
            stage = .atShell
            log.notice("guest shell ready")
        }
        sendNextIfReady()
    }

    private func sendNextIfReady() {
        guard stage == .atShell, inFlight == nil, let next = pending.first else { return }
        pending.removeFirst()
        inFlight = next
        console.send("\(next.command); echo \(Self.sentinel(for: next.id))")
    }

    private func nudgeIfStalled() {
        guard stage != .idle, stage != .atShell else { return }
        guard Date.now.timeIntervalSince(lastActionAt) > 8 else { return }
        console.send("")
    }
}
