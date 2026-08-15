import Foundation
import Virtualization

struct ConsoleLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

@MainActor
final class SerialConsole: ObservableObject {
    static let shared = SerialConsole()

    @Published private(set) var lines: [ConsoleLine] = []
    @Published private(set) var isAttached = false

    var onLine: ((String) -> Void)?
    var onTail: ((String) -> Void)?

    private static let maxLines = 400
    private var nextLineID = 0
    private var partial = ""
    private var pipe: Pipe?
    private var hostWriter: Pipe?
    private var flushTimer: Timer?
    private var logHandle: FileHandle?
    private let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func beginFileLog(at url: URL) {
        endFileLog()
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }

    func endFileLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func fileLog(_ text: String) {
        guard let handle = logHandle else { return }
        try? handle.write(contentsOf: Data("\(logStamp.string(from: .now)) \(text)\n".utf8))
    }

    private nonisolated(unsafe) var rawBuffer = ""
    private nonisolated let bufferLock = NSLock()

    private init() {}

    nonisolated func makeConfiguration() -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        let guestToHost = Pipe()
        let hostToGuest = Pipe()

        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: hostToGuest.fileHandleForReading,
            fileHandleForWriting: guestToHost.fileHandleForWriting
        )

        guestToHost.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            bufferLock.lock()
            rawBuffer += text
            bufferLock.unlock()
        }

        Task { @MainActor in
            self.pipe = guestToHost
            self.hostWriter = hostToGuest
            self.isAttached = true
            self.startFlushing()
        }
        return port
    }

    private(set) var lastGuestOutputAt: Date?

    func send(_ command: String) {
        guard let writer = hostWriter, let data = (command + "\n").data(using: .utf8) else { return }
        if !command.isEmpty {
            append(text: "> " + command)
        }
        try? writer.fileHandleForWriting.write(contentsOf: data)
    }

    func clear() {
        lines.removeAll()
        partial = ""
        lastGuestOutputAt = nil
    }

    func detach() {
        flushTimer?.invalidate()
        flushTimer = nil
        isAttached = false
        hostWriter = nil
        pipe = nil
    }

    var transcript: String {
        lines.map(\.text).joined(separator: "\n")
    }

    private func startFlushing() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        bufferLock.lock()
        let chunk = rawBuffer
        rawBuffer = ""
        bufferLock.unlock()
        guard !chunk.isEmpty else { return }
        ingest(chunk)
    }

    private func ingest(_ chunk: String) {
        lastGuestOutputAt = .now
        partial += chunk
        var completed = partial.components(separatedBy: "\n")
        partial = completed.removeLast()

        let cleaned = completed
            .map(ConsoleText.strippedOfControlSequences)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in cleaned {
            append(text: line)
            onLine?(line)
        }
        onTail?(ConsoleText.strippedOfControlSequences(partial))
    }

    private func append(text: String) {
        fileLog(text)
        lines.append(ConsoleLine(id: nextLineID, text: text))
        nextLineID += 1
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}
