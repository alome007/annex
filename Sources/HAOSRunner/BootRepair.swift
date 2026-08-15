import Foundation

enum GrubEnvironment {
    static let blockSize = 1024

    static func resettingTryCounters(_ data: Data) -> Data? {
        guard data.count == blockSize, let text = String(data: data, encoding: .ascii) else { return nil }
        let entries = text.split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains("=") }
        guard !entries.isEmpty else { return nil }
        var content = "# GRUB Environment Block\n"
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            content += key.hasSuffix("_TRY") ? "\(key)=0\n" : "\(key)=\(value)\n"
        }
        guard content.count <= blockSize else { return nil }
        return Data((content + String(repeating: "#", count: blockSize - content.count)).utf8)
    }
}

enum BootRepairError: LocalizedError {
    case attachFailed(String)
    case bootVolumeMissing
    case grubEnvironmentInvalid

    var errorDescription: String? {
        switch self {
        case .attachFailed(let detail):
            "The disk image could not be opened for repair: \(detail)"
        case .bootVolumeMissing:
            "The disk's boot volume (hassos-boot) did not mount."
        case .grubEnvironmentInvalid:
            "The boot configuration on the disk is not in the expected format."
        }
    }
}

enum BootRepair {
    static func resetBootSlots(diskImage: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try resetBlocking(diskImage: diskImage)
        }.value
    }

    private static func resetBlocking(diskImage: URL) throws {
        let attachOutput = try run(
            "/usr/bin/hdiutil",
            ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", diskImage.path(percentEncoded: false)]
        )
        guard let device = attachOutput
            .components(separatedBy: .whitespacesAndNewlines)
            .first(where: { $0.hasPrefix("/dev/disk") }) else {
            throw BootRepairError.attachFailed(attachOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", device]) }

        _ = try run("/usr/sbin/diskutil", ["mount", "\(device)s1"])
        defer { _ = try? run("/usr/sbin/diskutil", ["unmount", "\(device)s1"]) }

        let grubenv = URL(fileURLWithPath: "/Volumes/hassos-boot/EFI/BOOT/grubenv")
        guard FileManager.default.fileExists(atPath: grubenv.path) else {
            throw BootRepairError.bootVolumeMissing
        }
        let current = try Data(contentsOf: grubenv)
        guard let repaired = GrubEnvironment.resettingTryCounters(current) else {
            throw BootRepairError.grubEnvironmentInvalid
        }
        try repaired.write(to: grubenv)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw BootRepairError.attachFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
