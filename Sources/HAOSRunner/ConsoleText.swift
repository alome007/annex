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
    static func reportsNoInternet(_ line: String) -> Bool {
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
