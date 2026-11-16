import Foundation
import Network

/// Accepts connections on this Mac and relays each one to the guest.
///
/// With NAT networking the guest has an address only this Mac can reach. A
/// listener on the Mac's own interfaces is what lets a phone on the same
/// network open Home Assistant.
final class PortForwarder: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    private struct Route: Equatable {
        let port: UInt16
        let host: String
        let targetPort: UInt16
    }

    /// Called on an arbitrary queue whenever the listener's state changes.
    var onStateChange: (@Sendable (State) -> Void)?

    // Every stored property below is touched only on this queue.
    private let queue = DispatchQueue(label: "casa.astrohome.haosrunner.forwarder")
    private var listener: NWListener?
    private var route: Route?
    private var open: [ObjectIdentifier: NWConnection] = [:]

    /// Starts relaying `port` on this Mac to `host:targetPort`. Asking again
    /// for the route already in place changes nothing, so open connections
    /// survive unrelated settings changes.
    ///
    /// - Parameter port: 0 lets the system pick a free port.
    func start(port: UInt16, host: String, targetPort: UInt16) {
        queue.async { [self] in
            let wanted = Route(port: port, host: host, targetPort: targetPort)
            guard route != wanted else { return }
            shutDown()
            route = wanted
            listen(on: wanted)
        }
    }

    func stop() {
        queue.async { [self] in shutDown(reporting: true) }
    }

    /// - Parameter reporting: announce `.stopped`, and only once the listening
    ///   socket is really closed, so "stopped" never describes a port that
    ///   still accepts connections.
    private func shutDown(reporting: Bool = false) {
        if let listener {
            listener.stateUpdateHandler = reporting ? { [weak self, listener] state in
                guard case .cancelled = state else { return }
                listener.stateUpdateHandler = nil
                self?.onStateChange?(.stopped)
            } : nil
            listener.cancel()
        } else if reporting {
            onStateChange?(.stopped)
        }
        listener = nil
        route = nil
        open.values.forEach { $0.cancel() }
        open = [:]
    }

    private func listen(on route: Route) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            let port = route.port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: route.port)!
            listener = try NWListener(using: parameters, on: port)
        } catch {
            fail(error, route)
            return
        }
        let target = NWEndpoint.hostPort(
            host: NWEndpoint.Host(route.host),
            port: NWEndpoint.Port(rawValue: route.targetPort)!
        )
        listener.newConnectionHandler = { [weak self] inbound in
            self?.relay(inbound, to: target)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                self?.onStateChange?(.listening(port: listener?.port?.rawValue ?? route.port))
            case .failed(let error), .waiting(let error):
                self?.fail(error, route)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func fail(_ error: Error, _ route: Route) {
        let message: String
        if case .posix(.EADDRINUSE)? = error as? NWError {
            message = "Port \(route.port) is already in use on this Mac."
        } else {
            message = error.localizedDescription
        }
        shutDown()
        onStateChange?(.failed(message))
    }

    private func relay(_ inbound: NWConnection, to target: NWEndpoint) {
        let outbound = NWConnection(to: target, using: .tcp)
        let key = ObjectIdentifier(inbound)
        open[key] = inbound
        let close: () -> Void = { [weak self] in
            inbound.cancel()
            outbound.cancel()
            self?.open[key] = nil
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound, onEnd: close)
        pump(from: outbound, to: inbound, onEnd: close)
    }

    private func pump(from source: NWConnection, to sink: NWConnection, onEnd: @escaping () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                onEnd()
                return
            }
            sink.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil || isComplete || error != nil {
                    onEnd()
                } else {
                    self?.pump(from: source, to: sink, onEnd: onEnd)
                }
            })
        }
    }
}

enum LocalNetwork {
    /// This Mac's address on the local network: the first Ethernet or Wi-Fi
    /// interface that is up and has an IPv4 address.
    static func address() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }

        var found: [(name: String, address: String)] = []
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress, socklen_t(socketAddress.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            if result == 0 { found.append((name, String(cString: host))) }
        }
        return found.sorted { $0.name < $1.name }.first?.address
    }
}
