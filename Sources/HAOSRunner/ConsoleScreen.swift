import SwiftUI

/// The machine's serial console: what it prints, and a line to type into it.
struct ConsoleScreen: View {
    let console: ConsoleContent
    @State private var command = ""
    @Environment(\.windowActions) private var actions

    var body: some View {
        Page(scrolls: false, topInset: 20) {
            CopyButton(text: console.lines.map(\.text).joined(separator: "\n"), help: "Copy the console text")
            IconButton(glyph: .trash, help: "Clear the console", action: actions.clearConsole)
                .disabled(console.lines.isEmpty)
        } content: {
            VStack(spacing: 0) {
                TextPane(
                    count: console.lines.count,
                    emptyText: "What the machine prints while it starts and runs appears here."
                ) {
                    ForEach(console.lines) { line in
                        Text(line.text)
                            .font(.mono(11, line.text.hasPrefix("> ") ? .medium : .regular))
                            .foregroundStyle(line.text.hasPrefix("> ") ? Theme.ink : Theme.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                input
            }
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(.mono(12, .medium))
                .foregroundStyle(console.isAttached ? Theme.ink : Theme.faint)
                .accessibilityHidden(true)
            TextField(
                console.isAttached ? "Type a command for the machine and press Return" : "Available once the machine starts",
                text: $command
            )
            .textFieldStyle(.plain)
            .font(.mono(12))
            .foregroundStyle(Theme.ink)
            .disabled(!console.isAttached)
            .onSubmit(send)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .glass(in: Corner.shape(Corner.control))
        .padding(.top, 10)
    }

    private func send() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actions.sendConsoleCommand(trimmed)
        command = ""
    }
}
