import Foundation
import Virtualization

struct ConsoleLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Turns the bytes the guest writes into whole lines.
///
/// Reads end at arbitrary byte offsets, so text is only decoded up to the last
/// newline: decoding each read on its own would break any character that
/// straddles two of them.
struct LineAssembler {
    private var unfinished = Data()

    /// The text after the last newline: the line still being written.
    var tail: String { String(decoding: unfinished, as: UTF8.self) }

    /// Adds newly read bytes and returns the lines they completed.
    mutating func ingest(_ data: Data) -> [String] {
        unfinished.append(data)
        guard let lastNewline = unfinished.lastIndex(of: 0x0A) else { return [] }
        let complete = unfinished[..<lastNewline]
        unfinished = Data(unfinished[unfinished.index(after: lastNewline)...])
        return String(decoding: complete, as: UTF8.self).components(separatedBy: "\n")
    }

    mutating func reset() {
        unfinished = Data()
    }
}

@MainActor
final class SerialConsole: ObservableObject {
    static let shared = SerialConsole()

    @Published private(set) var lines: [ConsoleLine] = []
    @Published private(set) var isAttached = false

    /// Receives every line the guest prints. Returning true marks the line as
    /// the app's own command traffic: it is written to the log file but kept
    /// off the screen.
    var onLine: ((String) -> Bool)?
    var onTail: ((String) -> Void)?

    private static let maxLines = 400
    private static let maxLoggedLineLength = 400
    /// The log file starts over at this size. The app's own polling adds a few
    /// lines every few seconds for as long as the machine runs.
    private static let maxLogBytes = 16 * 1024 * 1024
    private var loggedBytes = 0
    private var nextLineID = 0
    private var assembler = LineAssembler()
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
        loggedBytes = 0
    }

    func endFileLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func fileLog(_ text: String) {
        guard let handle = logHandle else { return }
        let entry = Data("\(logStamp.string(from: .now)) \(text.prefix(Self.maxLoggedLineLength))\n".utf8)
        if loggedBytes + entry.count > Self.maxLogBytes {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
            loggedBytes = 0
        }
        try? handle.write(contentsOf: entry)
        loggedBytes += entry.count
    }

    private nonisolated(unsafe) var rawBuffer = Data()
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
            guard !data.isEmpty else { return }
            bufferLock.lock()
            rawBuffer.append(data)
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

    /// Types a line into the guest's terminal.
    ///
    /// - Parameter visible: whether the line is shown in the on-screen console.
    ///   Commands the app sends for itself are not.
    func send(_ command: String, visible: Bool = true) {
        guard let writer = hostWriter, let data = (command + "\n").data(using: .utf8) else { return }
        if !command.isEmpty {
            record("> " + command, visible: visible)
        }
        try? writer.fileHandleForWriting.write(contentsOf: data)
    }

    func clear() {
        lines.removeAll()
        assembler.reset()
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
            guard let self else { return }
            Task { @MainActor in self.flush() }
        }
    }

    private func flush() {
        bufferLock.lock()
        let chunk = rawBuffer
        rawBuffer = Data()
        bufferLock.unlock()
        guard !chunk.isEmpty else { return }
        ingest(chunk)
    }

    private func ingest(_ chunk: Data) {
        lastGuestOutputAt = .now
        for raw in assembler.ingest(chunk) {
            let line = ConsoleText.strippedOfControlSequences(raw)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let appTraffic = onLine?(line) ?? false
            record(trimmed, visible: !appTraffic)
        }
        onTail?(ConsoleText.strippedOfControlSequences(assembler.tail))
    }

    private func record(_ text: String, visible: Bool) {
        fileLog(text)
        guard visible else { return }
        lines.append(ConsoleLine(id: nextLineID, text: text))
        nextLineID += 1
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}
