import SwiftUI

/// The logs Home Assistant keeps, one source at a time.
struct LogsScreen: View {
    let status: MachineStatus
    @ObservedObject var home: HomeAssistantStore
    @Binding var source: LogSource

    @State private var filter = ""
    @State private var follows = false

    private var sources: [LogSource] {
        [.core, .supervisor, .host] + home.apps.map { .app(slug: $0.slug, name: $0.name) }
    }

    private var lines: [String] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return home.logLines }
        return home.logLines.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        Page(scrolls: false, topInset: 20) {
            if status.address != nil {
                Toggle("Follow", isOn: $follows)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.ui(12))
                    .foregroundStyle(Theme.secondary)
                    .tint(Theme.secondary)
                    .help("Reload the log every five seconds")
                Picker("Source", selection: $source) {
                    ForEach(sources, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                SearchField(prompt: "Filter lines", text: $filter)
                CopyButton(text: lines.joined(separator: "\n"), help: "Copy the lines shown")
            }
        } content: {
            if status.address != nil {
                TextPane(count: lines.count, emptyText: emptyText) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.mono(11, Self.isProblem(line) ? .semibold : .regular))
                            .foregroundStyle(Self.isProblem(line) ? Theme.ink : Theme.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .task(id: LoadKey(source: source, follows: follows)) {
                    await home.loadLog(source)
                    while follows, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        await home.loadLog(source)
                    }
                }
            } else {
                OfflineState(message: "Logs are read from Home Assistant while it is running.", status: status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private struct LoadKey: Hashable {
        let source: LogSource
        let follows: Bool
    }

    private var emptyText: String {
        if home.isLoadingLog { return "Reading the \(source.title) log" }
        return filter.isEmpty ? "The \(source.title) log is empty." : "No line contains \"\(filter)\"."
    }

    /// Errors and warnings stand out by weight and strength, not colour.
    private static func isProblem(_ line: String) -> Bool {
        line.contains(" ERROR ") || line.contains(" CRITICAL ") || line.contains(" WARNING ")
    }
}

/// A bordered pane of machine text that fills the space it is given and keeps
/// its newest line in view.
struct TextPane<Lines: View>: View {
    /// How many lines are shown; a change scrolls the newest into view.
    let count: Int
    let emptyText: String
    @ViewBuilder let lines: Lines

    private static var bottom: String { "bottom" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    lines
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(14)
            }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: count) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if count == 0 {
                Text(emptyText)
                    .font(.ui(12))
                    .foregroundStyle(Theme.faint)
            }
        }
        .background(Theme.fill, in: Corner.shape(Corner.surface))
        .overlay(Corner.shape(Corner.surface).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
