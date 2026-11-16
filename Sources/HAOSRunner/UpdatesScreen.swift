import SwiftUI

/// What is installed at which version, and what has a newer one waiting.
struct UpdatesScreen: View {
    let status: MachineStatus
    @ObservedObject var home: HomeAssistantStore
    @State private var confirming: UpdateItem?

    private struct Entry: Identifiable {
        let name: String
        let installed: String?
        let update: UpdateItem?
        var id: String { name }
    }

    private var entries: [Entry] {
        let updates = home.updates
        let info = home.system?.info
        let system = [
            Entry(name: "Home Assistant Core", installed: info?.homeassistant, update: updates.first { $0.target == .core }),
            Entry(name: "Operating system", installed: info?.hassos, update: updates.first { $0.target == .operatingSystem }),
            Entry(name: "Supervisor", installed: info?.supervisor, update: updates.first { $0.target == .supervisor }),
        ]
        let apps = updates
            .filter { if case .app = $0.target { true } else { false } }
            .map { Entry(name: $0.name, installed: $0.installed, update: $0) }
        return system + apps
    }

    var body: some View {
        Page(topInset: 20) {
            if status.address == nil {
                OfflineState(message: "Versions and updates are read from Home Assistant while it is running.", status: status)
            } else {
                SectionBlock(title: "Software") {
                    if home.system == nil {
                        Placeholder(text: "Reading versions from Home Assistant", isLoading: true)
                    } else {
                        ForEach(entries) { entry in
                            ListRow {
                                Text(entry.name)
                                    .font(.ui(13, .medium))
                                    .foregroundStyle(Theme.ink)
                                    .frame(width: 200, alignment: .leading)
                                Text(entry.installed ?? "Unknown")
                                    .font(.ui(13))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.secondary)
                                Spacer(minLength: 8)
                                trailing(for: entry)
                            }
                        }
                    }
                }
                .task { await home.refreshSystem() }
            }
        }
        .confirmationDialog(
            confirming.map { "Update \($0.name) to \($0.latest)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { update in
            Button("Update") { home.apply(update) }
            Button("Not now", role: .cancel) {}
        } message: { update in
            Text(update.target == .operatingSystem
                ? "The machine restarts to finish the update. Home Assistant is unavailable for a few minutes."
                : "Home Assistant restarts during the update and is unavailable for a few minutes.")
        }
    }

    @ViewBuilder private func trailing(for entry: Entry) -> some View {
        if let update = entry.update {
            if let activity = home.activity[update.target.key] {
                ActivityLabel(activity: activity)
            } else {
                Button("Update to \(update.latest)") {
                    // An app update only restarts that app, so it needs no warning.
                    if case .app = update.target { home.apply(update) } else { confirming = update }
                }
                .buttonStyle(RowButtonStyle())
            }
        } else {
            Text("Up to date")
                .font(.ui(12))
                .foregroundStyle(Theme.faint)
        }
    }
}
