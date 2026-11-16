import Network
import XCTest
@testable import HAOSRunner

/// Requirement: with sharing on, a connection made to this Mac reaches Home
/// Assistant and the answer comes back; with it off, nothing listens.
final class PortForwarderTests: XCTestCase {
    private let queue = DispatchQueue(label: "port-forwarder-tests")

    /// A stand-in for Home Assistant that sends back whatever it receives.
    private func startEchoServer() throws -> (NWListener, UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        let ready = expectation(description: "echo server ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        return (listener, try XCTUnwrap(listener.port?.rawValue))
    }

    private func startForwarder(to targetPort: UInt16) -> (PortForwarder, UInt16) {
        let forwarder = PortForwarder()
        let listening = expectation(description: "forwarder listening")
        let port = LockedBox<UInt16>(0)
        forwarder.onStateChange = { state in
            if case .listening(let assigned) = state {
                port.value = assigned
                listening.fulfill()
            }
        }
        forwarder.start(port: 0, host: "127.0.0.1", targetPort: targetPort)
        wait(for: [listening], timeout: 5)
        return (forwarder, port.value)
    }

    func testBytesSentToTheSharedPortReachTheTargetAndTheAnswerReturns() throws {
        let (server, serverPort) = try startEchoServer()
        defer { server.cancel() }
        let (forwarder, sharedPort) = startForwarder(to: serverPort)
        defer { forwarder.stop() }

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: sharedPort)!, using: .tcp)
        defer { client.cancel() }
        let answered = expectation(description: "answer relayed back")
        client.start(queue: queue)
        client.send(content: Data("GET / HTTP/1.1".utf8), completion: .contentProcessed { _ in })
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
            XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "GET / HTTP/1.1")
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    func testNothingListensAfterSharingIsSwitchedOff() throws {
        let (server, serverPort) = try startEchoServer()
        defer { server.cancel() }
        let (forwarder, sharedPort) = startForwarder(to: serverPort)

        let stopped = expectation(description: "forwarder stopped")
        forwarder.onStateChange = { if $0 == .stopped { stopped.fulfill() } }
        forwarder.stop()
        wait(for: [stopped], timeout: 5)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: sharedPort)!, using: .tcp)
        defer { client.cancel() }
        let refused = expectation(description: "connection refused")
        client.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting: refused.fulfill()
            case .ready: XCTFail("the port still accepts connections")
            default: break
            }
        }
        client.start(queue: queue)
        wait(for: [refused], timeout: 5)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
