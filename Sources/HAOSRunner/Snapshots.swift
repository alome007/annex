import Foundation

/// A copy of the machine's disk kept on this Mac.
struct DiskSnapshot: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let createdAt: Date
    /// Set when the machine was suspended rather than shut down: the settings
    /// its saved memory belongs to. The memory is stored beside the disk so the
    /// pair can be resumed together.
    let suspendedSession: String?
}

/// Where the machine's files live and where its snapshots are kept.
struct MachineFiles {
    let disk: URL
    let firmware: URL
    let suspendedState: URL
    let snapshots: URL

    static let current = MachineFiles(
        disk: Paths.diskImage,
        firmware: Paths.efiStore,
        suspendedState: Paths.savedState,
        snapshots: Paths.support.appending(path: "Snapshots", directoryHint: .isDirectory)
    )
}

enum SnapshotError: LocalizedError {
    case diskMissing
    case snapshotIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .diskMissing:
            "There is no machine disk to copy yet."
        case .snapshotIncomplete(let name):
            "The snapshot \"\(name)\" has no disk file. Nothing was changed."
        }
    }
}

/// Snapshot files on disk. On APFS each copy is a clone: instant, and it takes
/// no space until the machine's disk and the copy start to differ.
enum SnapshotStore {
    private static let diskName = "haos.img"
    private static let firmwareName = "efi-vars.fd"
    private static let stateName = "machine-state.vzvmsave"
    private static let recordName = "snapshot.json"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Every snapshot, newest first.
    static func list(_ files: MachineFiles) -> [DiskSnapshot] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: files.snapshots,
            includingPropertiesForKeys: nil
        )) ?? []
        return folders
            .compactMap { try? Data(contentsOf: $0.appending(path: recordName)) }
            .compactMap { try? decoder.decode(DiskSnapshot.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Copies the machine as it is now. Call only while the machine is off.
    static func take(named name: String, suspendedSession: String?, files: MachineFiles) throws -> DiskSnapshot {
        let manager = FileManager.default
        guard manager.fileExists(atPath: files.disk.path(percentEncoded: false)) else {
            throw SnapshotError.diskMissing
        }
        let hasState = manager.fileExists(atPath: files.suspendedState.path(percentEncoded: false))
        let snapshot = DiskSnapshot(
            id: UUID(),
            name: name,
            createdAt: .now,
            suspendedSession: hasState ? suspendedSession : nil
        )
        let folder = self.folder(of: snapshot, files)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try manager.copyItem(at: files.disk, to: folder.appending(path: diskName))
            if manager.fileExists(atPath: files.firmware.path(percentEncoded: false)) {
                try manager.copyItem(at: files.firmware, to: folder.appending(path: firmwareName))
            }
            if snapshot.suspendedSession != nil {
                try manager.copyItem(at: files.suspendedState, to: folder.appending(path: stateName))
            }
            try encoder.encode(snapshot).write(to: folder.appending(path: recordName))
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        return snapshot
    }

    /// Replaces the machine's files with the snapshot's. The snapshot is kept.
    /// The current disk is only replaced once the copy that takes its place is
    /// complete, so a failed restore changes nothing.
    static func restore(_ snapshot: DiskSnapshot, files: MachineFiles) throws {
        let manager = FileManager.default
        let folder = self.folder(of: snapshot, files)
        let savedDisk = folder.appending(path: diskName)
        guard manager.fileExists(atPath: savedDisk.path(percentEncoded: false)) else {
            throw SnapshotError.snapshotIncomplete(snapshot.name)
        }
        try replace(files.disk, with: savedDisk)
        let savedFirmware = folder.appending(path: firmwareName)
        if manager.fileExists(atPath: savedFirmware.path(percentEncoded: false)) {
            try replace(files.firmware, with: savedFirmware)
        }
        // Memory saved against any other disk state would resume into corruption.
        try? manager.removeItem(at: files.suspendedState)
        if snapshot.suspendedSession != nil {
            try manager.copyItem(at: folder.appending(path: stateName), to: files.suspendedState)
        }
    }

    static func delete(_ snapshot: DiskSnapshot, files: MachineFiles) throws {
        try FileManager.default.removeItem(at: folder(of: snapshot, files))
    }

    private static func folder(of snapshot: DiskSnapshot, _ files: MachineFiles) -> URL {
        files.snapshots.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory)
    }

    private static func replace(_ target: URL, with source: URL) throws {
        let manager = FileManager.default
        let staged = target.appendingPathExtension("restoring")
        try? manager.removeItem(at: staged)
        try manager.copyItem(at: source, to: staged)
        if manager.fileExists(atPath: target.path(percentEncoded: false)) {
            _ = try manager.replaceItemAt(target, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: target)
        }
    }
}

/// The snapshot list the window shows, with the work done off the main thread.
@MainActor
final class SnapshotLibrary: ObservableObject {
    @Published private(set) var snapshots: [DiskSnapshot] = []
    @Published private(set) var isWorking = false

    private let files: MachineFiles

    init(files: MachineFiles) {
        self.files = files
        snapshots = SnapshotStore.list(files)
    }

    func take(named name: String, suspendedSession: String?) async throws {
        try await work { files in
            _ = try SnapshotStore.take(named: name, suspendedSession: suspendedSession, files: files)
        }
    }

    func restore(_ snapshot: DiskSnapshot) async throws {
        try await work { files in try SnapshotStore.restore(snapshot, files: files) }
    }

    func delete(_ snapshot: DiskSnapshot) async throws {
        try await work { files in try SnapshotStore.delete(snapshot, files: files) }
    }

    private func work(_ operation: @escaping @Sendable (MachineFiles) throws -> Void) async throws {
        isWorking = true
        defer {
            isWorking = false
            snapshots = SnapshotStore.list(files)
        }
        let files = self.files
        try await Task.detached(priority: .userInitiated) { try operation(files) }.value
    }
}
