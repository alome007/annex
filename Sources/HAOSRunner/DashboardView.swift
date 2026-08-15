import AppKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var controller: Controller
    @State private var consoleOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    statusSection
                    if case .running(let url) = controller.state {
                        AppsSection(homeAssistantURL: url)
                    }
                    ConsoleSection(isOpen: $consoleOpen)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.page)
        .frame(minWidth: 640, minHeight: 520)
        .onChange(of: controller.state) { _, newState in
            if case .failed = newState {
                consoleOpen = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(state: controller.state)
            Text("Home Assistant")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Theme.ink)
            Text(statusWord)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
            Spacer()
            SettingsButton()
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 4)
    }

    private var statusWord: String {
        switch controller.state {
        case .ready: "ready"
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .stopped: "off"
        case .failed: "error"
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(StateDescription.headline(for: controller.state, hasDisk: Paths.hasWorkingDisk))
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.ink)
                if !detailIsError {
                    Text(StateDescription.detail(for: controller.state, hasDisk: Paths.hasWorkingDisk))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .starting(let stage) = controller.state {
                BootChecklist(
                    current: stage,
                    bootStartedAt: controller.bootStartedAt,
                    freshInstall: controller.freshInstall
                )
            }
            if case .running(let url) = controller.state {
                AddressBlock(url: url)
            }
            if case .failed(let message) = controller.state {
                ErrorBlock(message: message)
            }

            actionRow
        }
    }

    private var detailIsError: Bool {
        if case .failed = controller.state { return true }
        return false
    }

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 10) {
            switch controller.state {
            case .ready, .stopped:
                Button(Paths.hasWorkingDisk ? "Start Home Assistant" : "Install Home Assistant") { controller.start() }
                    .buttonStyle(PrimaryButtonStyle())
            case .starting:
                Button("Force stop") { controller.forceStop() }
                    .buttonStyle(QuietButtonStyle())
            case .running(let url):
                Button("Open Home Assistant") { NSWorkspace.shared.open(url) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Stop") { controller.stop() }
                    .buttonStyle(QuietButtonStyle())
            case .stopping:
                ProgressView().controlSize(.small)
                Button("Force stop") { controller.forceStop() }
                    .buttonStyle(QuietButtonStyle())
            case .failed:
                if controller.machineIsActive {
                    Button("Force stop") { controller.forceStop() }
                        .buttonStyle(QuietButtonStyle())
                } else if controller.offerBootRepair {
                    Button("Repair startup") { controller.repairAndRestart() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Start again") { controller.start() }
                        .buttonStyle(QuietButtonStyle())
                } else {
                    Button("Start again") { controller.start() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }
}

struct SectionEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.faint)
    }
}

private struct BootChecklist: View {
    let current: BootStage
    let bootStartedAt: Date?
    let freshInstall: Bool

    private var rows: [BootStage] {
        let standard: [BootStage] = [
            .startingMachine,
            .waitingForNetwork,
            .waitingForHomeAssistant(downloadPercent: nil),
            .connectingBridge,
        ]
        switch current {
        case .downloadingImage:
            return [.downloadingImage(percent: nil), .preparingDisk] + standard
        case .preparingDisk:
            return [.preparingDisk] + standard
        default:
            return standard
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SectionEyebrow(text: "BOOT SEQUENCE")
                if let bootStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: bootStartedAt, to: context.date))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            .padding(.bottom, 14)

            ForEach(Array(rows.enumerated()), id: \.element.ordinal) { index, row in
                StageRow(
                    stage: row,
                    current: current,
                    freshInstall: freshInstall,
                    isLast: index == rows.count - 1
                )
            }
        }
        .padding(.top, 4)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }
}

private struct StageRow: View {
    let stage: BootStage
    let current: BootStage
    let freshInstall: Bool
    let isLast: Bool

    private enum Status { case done, active, pending }

    private var status: Status {
        if stage.ordinal < current.ordinal { return .done }
        if stage.ordinal == current.ordinal { return .active }
        return .pending
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 3) {
                indicator.frame(width: 16, height: 16)
                if !isLast {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(status == .done ? Theme.running.opacity(0.45) : Theme.divider)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, 3)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(stage.title)
                    .font(.system(size: 13, weight: status == .active ? .medium : .regular))
                    .foregroundStyle(titleColor)
                if status == .active, let note = activeNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                if status == .active, let percent = activePercent {
                    ProgressBar(fraction: Double(percent) / 100)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, isLast ? 0 : 16)
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: status == .done)
    }

    @ViewBuilder private var indicator: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.running)
        case .active:
            ProgressView().controlSize(.mini)
        case .pending:
            Circle().stroke(Theme.divider, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }

    private var titleColor: Color {
        switch status {
        case .done: Theme.secondary
        case .active: Theme.ink
        case .pending: Theme.faint
        }
    }

    private var activePercent: Int? {
        switch current {
        case .downloadingImage(let percent): percent
        case .waitingForHomeAssistant(let percent): percent
        default: nil
        }
    }

    private var activeNote: String? {
        switch current {
        case .downloadingImage(let percent):
            if let percent {
                "Fetching the latest official image — \(percent)%"
            } else {
                "Looking up the latest official image (about 350 MB)."
            }
        case .preparingDisk:
            "Unpacking the image into a working disk."
        case .waitingForHomeAssistant(let percent):
            if let percent {
                "Downloading Home Assistant — \(percent)%"
            } else if freshInstall {
                "Downloading Home Assistant. This can take 10–20 minutes."
            } else {
                "Home Assistant is starting up. This usually takes about a minute."
            }
        case .connectingBridge:
            "Setting up the connection so your browser can reach it."
        default:
            nil
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.divider)
                Capsule()
                    .fill(Theme.ink)
                    .frame(width: geometry.size.width * min(1, max(0.02, fraction)))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            }
        }
        .frame(width: 220, height: 4)
    }
}

private struct AddressBlock: View {
    let url: URL
    @StateObject private var copy = CopyFlash()

    var body: some View {
        HStack(spacing: 10) {
            Text(url.absoluteString)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            CopyIconButton(flash: copy, text: url.absoluteString, help: "Copy address")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 460)
    }
}

private struct ErrorBlock: View {
    let message: String
    @StateObject private var copy = CopyFlash()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.error)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            CopyIconButton(flash: copy, text: message, help: "Copy error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AppsSection: View {
    @EnvironmentObject private var controller: Controller
    let homeAssistantURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "APPS")
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(AppCatalog.popular.enumerated()), id: \.element.id) { index, app in
                    AppRow(app: app, homeAssistantURL: homeAssistantURL)
                    if index < AppCatalog.popular.count - 1 {
                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 42)
                    }
                }
            }
            Button {
                NSWorkspace.shared.open(homeAssistantURL.appending(path: "_my_redirect/supervisor_store"))
            } label: {
                Text("Browse all apps in Home Assistant →")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }
}

private struct AppRow: View {
    let app: HAAddon
    let homeAssistantURL: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(
                homeAssistantURL
                    .appending(path: "_my_redirect/supervisor_addon")
                    .appending(queryItems: [URLQueryItem(name: "addon", value: app.id)])
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: app.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(app.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(app.name) in Home Assistant")
    }
}

@MainActor
enum ImagePicker {
    static func chooseSourceImage(controller: Controller) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Home Assistant OS image"
        panel.message = "Pick a generic-aarch64 .qcow2, .img or .img.xz from the Home Assistant OS releases."
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Paths.sourceImage = url
        controller.noteSettingsChanged()
    }
}
