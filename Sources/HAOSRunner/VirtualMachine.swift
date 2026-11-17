import Foundation
import Virtualization

enum Persistence {
    static let defaults: UserDefaults = {
        guard let suite = ProcessInfo.processInfo.environment["ANNEX_DEFAULTS_SUITE"] else {
            return .standard
        }
        guard let overridden = UserDefaults(suiteName: suite) else {
            fatalError("Invalid ANNEX_DEFAULTS_SUITE: \(suite)")
        }
        return overridden
    }()
}

enum Paths {
    static let support: URL = {
        if let overridden = ProcessInfo.processInfo.environment["ANNEX_SUPPORT_DIR"] {
            return URL(fileURLWithPath: overridden, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/HAOSRunner", directoryHint: .isDirectory)
    }()

    static let diskImage = support.appending(path: "haos.img")
    static let efiStore = support.appending(path: "efi-vars.fd")
    static let savedState = support.appending(path: "machine-state.vzvmsave")

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    private static let sourceKey = "sourceImagePath"

    static var sourceImage: URL? {
        get {
            guard let path = Persistence.defaults.string(forKey: sourceKey),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { Persistence.defaults.set(newValue?.path(percentEncoded: false), forKey: sourceKey) }
    }

    static var hasWorkingDisk: Bool {
        FileManager.default.fileExists(atPath: diskImage.path(percentEncoded: false))
    }
}

struct VMSettings: Equatable {
    var memoryGB: Int = 4
    var cpuCount: Int = 4
    var startOnLaunch: Bool = false
    var bridgedNetworking: Bool = false
    /// Relay a port on this Mac to Home Assistant for other devices on the network.
    var shareOnNetwork: Bool = false
    /// Notify when Home Assistant comes up or a start fails.
    var notifications: Bool = false
    /// The USB device plugged into the machine whenever it is plugged into this Mac.
    var usbDevice: USBDevice?

    static let memoryRange = 2...16
    static let cpuRange = 2...8
    /// Home Assistant's usual port, so the shared address looks like any other install.
    static let sharePort: UInt16 = 8123

    private static let memoryKey = "memoryGB"
    private static let cpuKey = "cpuCount"
    private static let startOnLaunchKey = "startOnLaunch"
    private static let bridgedNetworkingKey = "bridgedNetworking"
    private static let shareOnNetworkKey = "shareOnNetwork"
    private static let notificationsKey = "notifications"
    private static let usbDeviceKey = "usbDevice"

    static var bridgedInterface: VZBridgedNetworkInterface? {
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        return interfaces.first { $0.identifier == "en0" } ?? interfaces.first
    }

    static func load(from defaults: UserDefaults = Persistence.defaults) -> VMSettings {
        var settings = VMSettings()
        let storedMemory = defaults.integer(forKey: memoryKey)
        let storedCPU = defaults.integer(forKey: cpuKey)
        if memoryRange.contains(storedMemory) { settings.memoryGB = storedMemory }
        if cpuRange.contains(storedCPU) { settings.cpuCount = storedCPU }
        settings.startOnLaunch = defaults.bool(forKey: startOnLaunchKey)
        settings.bridgedNetworking = defaults.bool(forKey: bridgedNetworkingKey)
        settings.shareOnNetwork = defaults.bool(forKey: shareOnNetworkKey)
        settings.notifications = defaults.bool(forKey: notificationsKey)
        settings.usbDevice = defaults.data(forKey: usbDeviceKey).flatMap { try? JSONDecoder().decode(USBDevice.self, from: $0) }
        return settings
    }

    func save(to defaults: UserDefaults = Persistence.defaults) {
        defaults.set(memoryGB, forKey: Self.memoryKey)
        defaults.set(cpuCount, forKey: Self.cpuKey)
        defaults.set(startOnLaunch, forKey: Self.startOnLaunchKey)
        defaults.set(bridgedNetworking, forKey: Self.bridgedNetworkingKey)
        defaults.set(shareOnNetwork, forKey: Self.shareOnNetworkKey)
        defaults.set(notifications, forKey: Self.notificationsKey)
        defaults.set(usbDevice.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.usbDeviceKey)
    }
}

enum SavedSession {
    private static let configKey = "savedStateConfig"

    static var exists: Bool {
        FileManager.default.fileExists(atPath: Paths.savedState.path(percentEncoded: false))
    }

    static func record(_ settings: VMSettings) {
        Persistence.defaults.set(fingerprint(settings), forKey: configKey)
    }

    static func matches(_ settings: VMSettings) -> Bool {
        Persistence.defaults.string(forKey: configKey) == fingerprint(settings)
    }

    static func discard() {
        try? FileManager.default.removeItem(at: Paths.savedState)
        Persistence.defaults.removeObject(forKey: configKey)
    }

    /// The settings the suspended session on disk was saved under, if there is one.
    static var recordedFingerprint: String? {
        exists ? Persistence.defaults.string(forKey: configKey) : nil
    }

    /// Takes over a suspended session that a restored snapshot put back on disk.
    static func adopt(fingerprint: String) {
        Persistence.defaults.set(fingerprint, forKey: configKey)
    }

    /// What a suspended session depends on. Builds without USB support leave
    /// the old form unchanged, so updating never discards their sessions.
    static func fingerprint(_ settings: VMSettings, usbController: Bool = USBPassthrough.isAvailable) -> String {
        "\(settings.memoryGB)gb-\(settings.cpuCount)cpu-\(settings.bridgedNetworking ? "bridged" : "nat")"
            + (usbController ? "-usb" : "")
    }
}

enum VMError: LocalizedError {
    case diskImageMissing
    case noSourceImage
    case toolMissing(String)
    case configurationInvalid(String)
    case bridgedNetworkingUnavailable

    var errorDescription: String? {
        switch self {
        case .diskImageMissing:
            "No Home Assistant disk exists yet. Start Home Assistant to create one."
        case .bridgedNetworkingUnavailable:
            "Bridged networking is not available. macOS grants it only to apps signed with the com.apple.vm.networking entitlement."
        case .noSourceImage:
            "No image to build the disk from. Start Home Assistant to download one, or choose a file in settings."
        case .toolMissing(let name):
            "\(name) was not found. Install it (brew install qemu) so images can be converted."
        case .configurationInvalid(let detail):
            "The virtual machine configuration was rejected: \(detail)"
        }
    }
}

enum Tooling {
    static func locate(_ name: String) -> URL? {
        let roots = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in roots + fromPath {
            let candidate = URL(fileURLWithPath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return nil
    }
}

enum DiskSource: Equatable {
    case qcow2(URL)
    case rawImage(URL)
    case xzArchive(URL)
    case none

    static func resolve(userImage: URL?, cachedArchive: URL?) -> DiskSource {
        if let userImage {
            switch userImage.pathExtension.lowercased() {
            case "qcow2": return .qcow2(userImage)
            case "xz": return .xzArchive(userImage)
            default: return .rawImage(userImage)
            }
        }
        if let cachedArchive { return .xzArchive(cachedArchive) }
        return .none
    }
}

enum DiskBuilder {
    static let diskSizeBytes: UInt64 = 64 * 1024 * 1024 * 1024

    static var hasSource: Bool {
        DiskSource.resolve(userImage: Paths.sourceImage, cachedArchive: ImageDownloader.cachedArchive) != .none
    }

    static func rebuild() async throws {
        try await Task.detached(priority: .userInitiated) {
            try rebuildBlocking()
        }.value
    }

    private static func rebuildBlocking() throws {
        try Paths.ensureSupportDirectory()
        let building = Paths.support.appending(path: "haos.img.building")
        try? FileManager.default.removeItem(at: building)
        try? FileManager.default.removeItem(at: Paths.diskImage)
        try? FileManager.default.removeItem(at: Paths.efiStore)

        switch DiskSource.resolve(userImage: Paths.sourceImage, cachedArchive: ImageDownloader.cachedArchive) {
        case .qcow2(let source):
            try convertWithQemu(source, to: building)
        case .rawImage(let source):
            try FileManager.default.copyItem(at: source, to: building)
        case .xzArchive(let archive):
            try ImageDownloader.decompress(archive: archive, to: building)
        case .none:
            throw VMError.noSourceImage
        }
        try growDisk(at: building)
        try FileManager.default.moveItem(at: building, to: Paths.diskImage)
    }

    private static func convertWithQemu(_ source: URL, to destination: URL) throws {
        guard let qemuImg = Tooling.locate("qemu-img") else { throw VMError.toolMissing("qemu-img") }
        let convert = Process()
        convert.executableURL = qemuImg
        convert.arguments = [
            "convert", "-O", "raw",
            source.path(percentEncoded: false),
            destination.path(percentEncoded: false),
        ]
        try convert.run()
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else {
            throw VMError.configurationInvalid("Could not rebuild the disk from \(source.lastPathComponent).")
        }
    }

    private static func growDisk(at disk: URL) throws {
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        let current = try handle.seekToEnd()
        guard current < diskSizeBytes else { return }
        try handle.truncate(atOffset: diskSizeBytes)
    }
}

enum GuestAddressResolver {
    static func resolve(mac: String) async -> String? {
        await Task.detached {
            resolveBlocking(mac: mac)
        }.value
    }

    private static func resolveBlocking(mac: String) -> String? {
        if let leases = try? String(contentsOfFile: DHCPLeases.filePath, encoding: .utf8),
           let ip = DHCPLeases.ipAddress(forMAC: mac, in: leases) {
            return ip
        }
        if let table = runARP(), let ip = ARPTable.ipAddress(forMAC: mac, in: table) {
            return ip
        }
        return nil
    }

    private static func runARP() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

enum StableMAC {
    private static let key = "guestMACAddress"

    static func address() -> VZMACAddress {
        if let stored = Persistence.defaults.string(forKey: key), let mac = VZMACAddress(string: stored) {
            return mac
        }
        let fresh = VZMACAddress.randomLocallyAdministered()
        Persistence.defaults.set(fresh.string, forKey: key)
        return fresh
    }

    static var current: String? { Persistence.defaults.string(forKey: key) }
}

/// Virtualization restores a saved machine only into a configuration carrying
/// the identifier it was saved with, and a configuration left alone gets a new
/// random one each launch. Without a kept identifier every resume fails with
/// "invalid argument" and the suspended guest is cold booted instead.
enum StableMachineIdentifier {
    private static let key = "machineIdentifier"

    /// The machine's identifier, created and stored on first use.
    static func identifier(in defaults: UserDefaults = Persistence.defaults) -> VZGenericMachineIdentifier {
        if let stored = defaults.data(forKey: key),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: stored) {
            return identifier
        }
        let fresh = VZGenericMachineIdentifier()
        defaults.set(fresh.dataRepresentation, forKey: key)
        return fresh
    }
}

enum VMBuilder {
    @MainActor
    static func makeConfiguration(_ settings: VMSettings) throws -> VZVirtualMachineConfiguration {
        guard Paths.hasWorkingDisk else { throw VMError.diskImageMissing }

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = settings.cpuCount
        config.memorySize = UInt64(settings.memoryGB) * 1024 * 1024 * 1024

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = StableMachineIdentifier.identifier()
        config.platform = platform

        let loader = VZEFIBootLoader()
        loader.variableStore = try efiVariableStore()
        config.bootLoader = loader

        let attachment = try VZDiskImageStorageDeviceAttachment(url: Paths.diskImage, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = StableMAC.address()
        network.attachment = try networkAttachment(settings)
        config.networkDevices = [network]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.serialPorts = [SerialConsole.shared.makeConfiguration()]
        // Empty: the chosen device is plugged in once the machine runs.
        if #available(macOS 27, *), USBPassthrough.isAvailable {
            config.usbControllers = [VZXHCIControllerConfiguration()]
        }

        do {
            try config.validate()
        } catch {
            throw VMError.configurationInvalid(error.localizedDescription)
        }
        return config
    }

    private static func networkAttachment(_ settings: VMSettings) throws -> VZNetworkDeviceAttachment {
        guard settings.bridgedNetworking else { return VZNATNetworkDeviceAttachment() }
        guard let interface = VMSettings.bridgedInterface else { throw VMError.bridgedNetworkingUnavailable }
        return VZBridgedNetworkDeviceAttachment(interface: interface)
    }

    private static func efiVariableStore() throws -> VZEFIVariableStore {
        try Paths.ensureSupportDirectory()
        if FileManager.default.fileExists(atPath: Paths.efiStore.path(percentEncoded: false)) {
            return VZEFIVariableStore(url: Paths.efiStore)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: Paths.efiStore)
    }
}
