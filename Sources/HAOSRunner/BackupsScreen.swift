import SwiftUI

/// Two ways back: backups Home Assistant makes of itself, and copies of the
/// whole machine kept on this Mac.
struct BackupsScreen: View {
    let status: MachineStatus
    @ObservedObject var home: HomeAssistantStore
    @ObservedObject var snapshots: SnapshotLibrary
    let install: InstallOptions

    @State private var pending: Pending?
    @Environment(\.windowActions) private var actions

    /// A destructive action waiting for the user to confirm it.
    private enum Pending {
        case restoreBackup(Backup)
        case deleteBackup(Backup)
        case restoreSnapshot(DiskSnapshot)
        case deleteSnapshot(DiskSnapshot)

        var title: String {
            switch self {
            case .restoreBackup(let backup): "Restore \"\(backup.name)\"?"
            case .deleteBackup(let backup): "Delete \"\(backup.name)\"?"
            case .restoreSnapshot(let snapshot): "Restore the snapshot from \(snapshot.name)?"
            case .deleteSnapshot(let snapshot): "Delete the snapshot from \(snapshot.name)?"
            }
        }

        var message: String {
            switch self {
            case .restoreBackup:
                "Home Assistant's current configuration, history and apps are replaced with the backup's, and it restarts."
            case .deleteBackup:
                "The backup is removed from the machine. This cannot be undone."
            case .restoreSnapshot:
                "The machine's disk is replaced with this copy. Everything Home Assistant has stored since the snapshot is lost."
            case .deleteSnapshot:
                "The copy is removed from this Mac. This cannot be undone."
            }
        }

        var confirm: String {
            switch self {
            case .restoreBackup: "Restore backup"
            case .restoreSnapshot: "Restore snapshot"
            case .deleteBackup, .deleteSnapshot: "Delete"
            }
        }
    }

    var body: some View {
        Page(topInset: 20) {
            VStack(alignment: .leading, spacing: 34) {
                backupsSection
                snapshotsSection
            }
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirm, role: .destructive) { carryOut(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    private func carryOut(_ action: Pending) {
        switch action {
        case .restoreBackup(let backup): home.restore(backup)
        case .deleteBackup(let backup): home.delete(backup)
        case .restoreSnapshot(let snapshot): actions.restoreSnapshot(snapshot)
        case .deleteSnapshot(let snapshot): actions.deleteSnapshot(snapshot)
        }
    }

    // MARK: Home Assistant backups

    private var backupsSection: some View {
        SectionBlock(
            title: "Home Assistant backups",
            note: "Made by Home Assistant inside the machine: configuration, history and apps. They are stored on the machine's own disk."
        ) {
            if let activity = home.activity[HomeAssistantStore.newBackupKey] {
                ActivityLabel(activity: activity)
            } else {
                Button("Create backup") {
                    home.createBackup(named: "Annex \(Date.now.formatted(date: .abbreviated, time: .shortened))")
                }
                .buttonStyle(RowButtonStyle())
                .disabled(!home.isConnected)
            }
        } content: {
            if !home.isConnected {
                Placeholder(text: "Start Home Assistant to see and create its backups.")
            } else if !home.hasLoadedBackups {
                Placeholder(text: "Reading backups", isLoading: true)
            } else if home.backups.isEmpty {
                Placeholder(text: "No backups yet.")
            } else {
                ForEach(home.backups) { backup in
                    ListRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backup.name)
                                .font(.ui(13, .medium))
                                .foregroundStyle(Theme.ink)
                            Text(Self.description(of: backup))
                                .font(.ui(12))
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 8)
                        if let activity = home.activity["backup:\(backup.slug)"] {
                            ActivityLabel(activity: activity)
                        } else {
                            RowMenu(help: "Actions for \(backup.name)") {
                                Button("Restore…") { pending = .restoreBackup(backup) }
                                Divider()
                                Button("Delete…", role: .destructive) { pending = .deleteBackup(backup) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: status.address) { await home.refreshBackups() }
    }

    private static func description(of backup: Backup) -> String {
        var parts = [backup.type == "full" ? "Full backup" : "Partial backup"]
        if let created = backup.createdAt {
            parts.append("made \(created.formatted(date: .abbreviated, time: .shortened))")
        }
        if let size = backup.size {
            parts.append("\(size.formatted(.number.precision(.fractionLength(0...1)))) MB")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Disk snapshots

    private var snapshotsSection: some View {
        SectionBlock(
            title: "Disk snapshots",
            note: "An exact copy of the whole machine, kept on this Mac. A snapshot takes no extra space until the machine changes."
        ) {
            if snapshots.isWorking {
                ActivityLabel(activity: .init(title: "Working"))
            } else {
                Button("Take snapshot", action: actions.takeSnapshot)
                    .buttonStyle(RowButtonStyle())
                    .disabled(!install.canManageSnapshots || !status.hasDisk)
            }
        } content: {
            if status.isActive {
                Placeholder(text: "Stop Home Assistant to take or restore a snapshot. The disk can only be copied while the machine is off.")
            }
            if snapshots.snapshots.isEmpty {
                if !status.isActive { Placeholder(text: "No snapshots yet.") }
            } else {
                ForEach(snapshots.snapshots) { snapshot in
                    ListRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.name)
                                .font(.ui(13, .medium))
                                .foregroundStyle(Theme.ink)
                            Text(snapshot.suspendedSession == nil
                                ? "Taken with the machine shut down."
                                : "Taken with the machine suspended. Restoring resumes that session.")
                                .font(.ui(12))
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 8)
                        RowMenu(help: "Actions for the snapshot from \(snapshot.name)") {
                            Button("Restore…") { pending = .restoreSnapshot(snapshot) }
                                .disabled(!install.canManageSnapshots)
                            Divider()
                            Button("Delete…", role: .destructive) { pending = .deleteSnapshot(snapshot) }
                        }
                    }
                }
            }
        }
    }
}
