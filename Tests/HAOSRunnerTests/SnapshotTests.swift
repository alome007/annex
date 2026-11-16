import XCTest
@testable import HAOSRunner

/// Requirement: a snapshot is an exact copy of the machine that can be put
/// back later, and a restore that cannot finish leaves the machine as it was.
final class SnapshotStoreTests: XCTestCase {
    private var root: URL!
    private var files: MachineFiles!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "haosrunner-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = MachineFiles(
            disk: root.appending(path: "haos.img"),
            firmware: root.appending(path: "efi-vars.fd"),
            suspendedState: root.appending(path: "machine-state.vzvmsave"),
            snapshots: root.appending(path: "Snapshots", directoryHint: .isDirectory)
        )
        try write("disk v1", to: files.disk)
        try write("firmware v1", to: files.firmware)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(at url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testRestorePutsBackTheDiskAndFirmwareAsTheyWere() throws {
        let snapshot = try SnapshotStore.take(named: "before update", suspendedSession: nil, files: files)
        try write("disk v2", to: files.disk)
        try write("firmware v2", to: files.firmware)

        try SnapshotStore.restore(snapshot, files: files)

        XCTAssertEqual(text(at: files.disk), "disk v1")
        XCTAssertEqual(text(at: files.firmware), "firmware v1")
    }

    func testSnapshotSurvivesBeingRestoredAndCanBeRestoredAgain() throws {
        let snapshot = try SnapshotStore.take(named: "keep", suspendedSession: nil, files: files)
        try SnapshotStore.restore(snapshot, files: files)
        try write("disk v3", to: files.disk)

        try SnapshotStore.restore(snapshot, files: files)

        XCTAssertEqual(text(at: files.disk), "disk v1")
        XCTAssertEqual(SnapshotStore.list(files), [snapshot])
    }

    func testSuspendedMemoryTravelsWithTheDiskItBelongsTo() throws {
        try write("memory v1", to: files.suspendedState)
        let snapshot = try SnapshotStore.take(named: "suspended", suspendedSession: "4gb-4cpu-nat", files: files)
        XCTAssertEqual(snapshot.suspendedSession, "4gb-4cpu-nat")
        try write("disk v2", to: files.disk)
        try write("memory v2", to: files.suspendedState)

        try SnapshotStore.restore(snapshot, files: files)

        XCTAssertEqual(text(at: files.suspendedState), "memory v1")
    }

    func testRestoringAShutDownMachineDiscardsMemorySavedSince() throws {
        let snapshot = try SnapshotStore.take(named: "off", suspendedSession: nil, files: files)
        XCTAssertNil(snapshot.suspendedSession)
        try write("memory from a later session", to: files.suspendedState)

        try SnapshotStore.restore(snapshot, files: files)

        XCTAssertNil(text(at: files.suspendedState))
    }

    func testRestoreThatCannotFinishLeavesTheMachineUntouched() throws {
        let snapshot = try SnapshotStore.take(named: "damaged", suspendedSession: nil, files: files)
        let savedDisk = files.snapshots.appending(path: snapshot.id.uuidString).appending(path: "haos.img")
        try FileManager.default.removeItem(at: savedDisk)
        try write("disk v2", to: files.disk)

        XCTAssertThrowsError(try SnapshotStore.restore(snapshot, files: files))
        XCTAssertEqual(text(at: files.disk), "disk v2")
        XCTAssertEqual(text(at: files.firmware), "firmware v1")
    }

    func testSnapshotsAreListedNewestFirstAndDeletedOnesAreGone() throws {
        let first = try SnapshotStore.take(named: "first", suspendedSession: nil, files: files)
        let second = try SnapshotStore.take(named: "second", suspendedSession: nil, files: files)
        XCTAssertEqual(SnapshotStore.list(files).map(\.name), ["second", "first"])

        try SnapshotStore.delete(second, files: files)

        XCTAssertEqual(SnapshotStore.list(files).map(\.id), [first.id])
    }

    func testThereIsNothingToSnapshotBeforeTheMachineHasADisk() throws {
        try FileManager.default.removeItem(at: files.disk)
        XCTAssertThrowsError(try SnapshotStore.take(named: "none", suspendedSession: nil, files: files))
        XCTAssertTrue(SnapshotStore.list(files).isEmpty)
    }
}
