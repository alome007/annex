import Foundation
import os

/// Home Assistant serves its WebSocket cleanly to loopback-origin requests but
/// rejects ones arriving over the network, and `:8123` answers a WebSocket
/// upgrade with a redirect that browsers cannot follow. Onboarding and the live
/// dashboard therefore fail when the browser talks to Core directly, even
/// though every HTTP request and the upgrade handshake itself succeed — which
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
    static let progressCommand =
        "docker logs --since 2m hassio_supervisor 2>/dev/null | "
            + "grep -iE 'core image|supervisor connectivity|no supervisor internet|"
            + "has no home assistant version' | tail -n 2"
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

    /// `hassio_cli` is not always running, so every `docker exec hassio_cli ha …`
    /// can fail outright. Each step is therefore best-effort, the CLI is started
    /// first, and the parts that matter — the resolver and Supervisor itself —
    /// are driven through docker, which is always available on the host.
    static func repairCommand(gateway: String) -> String {
        "docker start hassio_cli >/dev/null 2>&1; "
            + "docker exec hassio_cli ha dns options --servers dns://\(gateway) || true; "
            + "docker restart hassio_dns >/dev/null; "
            + "docker restart hassio_supervisor >/dev/null"
    }

    /// Supervisor decides it has no internet from a single short-timeout request
    /// and then declines to fetch the version Core is installed from. On a slow
    /// link that check loses the race repeatedly, and nothing retries it hard
    /// enough — so nudge it until one attempt succeeds, gently if the CLI is up
    /// and by restarting Supervisor if it is not.
    static let nudgeCommand =
        "docker start hassio_cli >/dev/null 2>&1; "
            + "docker exec hassio_cli ha supervisor reload || docker restart hassio_supervisor >/dev/null"
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
