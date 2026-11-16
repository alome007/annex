import Foundation

enum BootStage: Equatable {
    case downloadingImage(percent: Int?)
    case preparingDisk
    case startingMachine
    case waitingForNetwork
    case waitingForHomeAssistant(downloadPercent: Int?)
    case connectingBridge

    var ordinal: Int {
        switch self {
        case .downloadingImage: 0
        case .preparingDisk: 1
        case .startingMachine: 2
        case .waitingForNetwork: 3
        case .waitingForHomeAssistant: 4
        case .connectingBridge: 5
        }
    }

    var title: String {
        switch self {
        case .downloadingImage: "Downloading Home Assistant OS"
        case .preparingDisk: "Preparing the disk"
        case .startingMachine: "Starting the machine"
        case .waitingForNetwork: "Waiting for the network"
        case .waitingForHomeAssistant: "Waiting for Home Assistant"
        case .connectingBridge: "Connecting the bridge"
        }
    }
}

enum VMState: Equatable {
    case ready
    case starting(BootStage)
    case running(url: URL)
    case stopping
    case stopped
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }

    var phase: String {
        switch self {
        case .ready: "ready"
        case .starting(let stage): "starting.\(stage.ordinal)"
        case .running: "running"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .failed: "failed"
        }
    }
}

struct PipelineFailure: Error {
    let message: String
}

/// What the window shows about the machine itself, as plain values, so every
/// screen can be drawn without a running machine behind it.
struct MachineStatus: Equatable {
    var state: VMState = .ready
    var hasDisk = false
    /// Whether a virtual machine exists, whatever it is doing.
    var isActive = false
    var bootStartedAt: Date?
    var freshInstall = false
    var downloadRegressed = false
    var guestOffline = false
    var download: SupervisorLog.Download?
    var bridgeUnavailable = false
    var offerBootRepair = false
    /// Whether a suspended session is on disk that the next start will resume.
    var canResume = false
    var sharing: PortForwarder.State = .stopped
    var sharedAddress: URL?

    var address: URL? {
        if case .running(let url) = state { return url }
        return nil
    }
}
