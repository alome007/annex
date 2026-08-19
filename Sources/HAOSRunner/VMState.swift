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
