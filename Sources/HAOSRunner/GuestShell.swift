import Foundation
import os

enum SupervisorProbe {
    static let progressCommand =
        "docker logs --since 2m hassio_supervisor 2>/dev/null | "
            + "grep -E 'Core image|no supervisor internet connection|has no Home Assistant version' | tail -n 2"
}

/// Home Assistant OS resolves names with its own CoreDNS, which prefers
/// DNS-over-TLS to public resolvers. Networks that block port 853 or those
/// resolvers leave the guest with no usable DNS — Supervisor then reports no
/// connectivity and never downloads Core. The Mac's own VM gateway forwards
/// DNS reliably, so pointing the guest at it is the repair.
enum GuestNetwork {
    static func gatewayAddress(forGuestIP ip: String) -> String? {
        let octets = ip.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return octets.dropLast().joined(separator: ".") + ".1"
    }

    static func repairCommand(gateway: String) -> String {
        "docker exec hassio_cli ha dns options --servers dns://\(gateway); "
            + "docker exec hassio_cli ha dns restart; "
            + "docker exec hassio_cli ha supervisor reload"
    }
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
            guard let self else { return }
            Task { @MainActor in self.nudgeIfStalled() }
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
