import Foundation

enum ConsoleText {
    static func strippedOfControlSequences(_ raw: String) -> String {
        var out = ""
        var iterator = raw.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "\u{1B}":
                consumeEscapeSequence(&iterator)
            case "\r", "\u{07}":
                continue
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func consumeEscapeSequence(_ iterator: inout String.UnicodeScalarView.Iterator) {
        guard let kind = iterator.next() else { return }
        switch kind {
        case "[":
            while let s = iterator.next() {
                if (0x40...0x7E).contains(s.value) { return }
            }
        case "]":
            while let s = iterator.next() {
                if s == "\u{07}" || s == "\u{1B}" { return }
            }
        default:
            return
        }
    }
}

enum GuestPrompt: Equatable {
    case gettyLogin
    case haCLI
    case rootShell

    static func classify(tail: String) -> GuestPrompt? {
        let lastLine = tail.components(separatedBy: "\n").last ?? ""
        let prompt = lastLine.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return nil }
        if prompt.lowercased().hasSuffix("login:") { return .gettyLogin }
        if prompt.hasSuffix("ha >") { return .haCLI }
        if prompt.hasSuffix("#") { return .rootShell }
        return nil
    }
}

enum SupervisorLog {
    /// A component Supervisor is pulling, named by the last word of its image.
    struct Download: Equatable {
        let component: String
        let version: String
    }

    /// Whether Supervisor itself logged this line.
    ///
    /// The console also echoes every command the app types, and an echoed
    /// command can contain the same phrases its output is searched for. Every
    /// Supervisor record carries its logger name, which no echo does.
    static func isRecord(_ line: String) -> Bool {
        line.contains("[supervisor.")
    }

    /// Reads the component and version from a record announcing a download.
    static func download(in line: String) -> Download? {
        guard isRecord(line),
              let start = line.range(of: "Downloading docker image "),
              let tag = line.range(of: " with tag ", range: start.upperBound..<line.endIndex),
              let component = line[start.upperBound..<tag.lowerBound]
                  .split(whereSeparator: { $0 == "/" || $0 == "-" }).last else { return nil }
        let version = line[tag.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !version.isEmpty else { return nil }
        return Download(component: String(component), version: version)
    }

    static func reportsNoInternet(_ line: String) -> Bool {
        guard isRecord(line) else { return false }
        let lowered = line.lowercased()
        return lowered.contains("no supervisor internet")
            || lowered.contains("no supervisor connectivity")
            || lowered.contains("has no home assistant version")
    }

    static func downloadPercent(in line: String) -> Int? {
        guard line.contains("Downloading"), line.contains("Core image") else { return nil }
        var digits = ""
        var lastPercent: Int?
        for ch in line {
            if ch.isNumber {
                digits.append(ch)
            } else {
                if ch == "%", let value = Int(digits), (0...100).contains(value) {
                    lastPercent = value
                }
                digits = ""
            }
        }
        return lastPercent
    }
}
