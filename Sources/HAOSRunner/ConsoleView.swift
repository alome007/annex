import SwiftUI

struct ConsoleSection: View {
    @Binding var isOpen: Bool
    @ObservedObject private var console = SerialConsole.shared
    @StateObject private var copy = CopyFlash()
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            disclosureHeader
            if isOpen {
                terminal
            }
        }
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(Theme.faint)
                SectionEyebrow(text: "CONSOLE")
                if !console.lines.isEmpty {
                    Text("\(console.lines.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1.5) {
                            ForEach(console.lines) { line in
                                Text(line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.text.hasPrefix("> ") ? Theme.accent : Theme.secondary)
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .onChange(of: console.lines.last?.id) { _, lastID in
                        guard let lastID else { return }
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
                HStack(spacing: 2) {
                    CopyIconButton(flash: copy, text: console.transcript, help: "Copy the log")
                    IconButton(symbol: "trash", help: "Clear", disabled: console.lines.isEmpty) {
                        console.clear()
                    }
                }
                .padding(6)
            }
            .frame(height: 240)
            .overlay {
                if console.lines.isEmpty {
                    Text("The boot log appears here once the machine starts.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
            }

            Rectangle().fill(Theme.divider).frame(height: 1)

            HStack(spacing: 8) {
                Text("›")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(console.isAttached ? Theme.accent : Theme.faint)
                TextField(
                    console.isAttached ? "Run a command in the guest console" : "Available once the machine starts",
                    text: $command
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .disabled(!console.isAttached)
                .onSubmit(send)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func send() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        console.send(trimmed)
        command = ""
    }
}
