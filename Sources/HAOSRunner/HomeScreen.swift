import SwiftUI

/// Home: the machine as a few glass widgets. Power and state on the left with
/// what the machine is using beside it, then its apps and its updates.
struct HomeScreen: View {
    let status: MachineStatus
    @ObservedObject var home: HomeAssistantStore
    let install: InstallOptions
    let settings: VMSettings
    @Binding var selectedVersion: String?
    /// Switches to the console, where a failed start explains itself.
    let showConsole: () -> Void
    /// Switches to the list of versions and waiting updates.
    let showUpdates: () -> Void
    /// Switches to the Apps screen.
    let showApps: () -> Void

    @State private var confirmingStop = false

    private static let sideWidth: CGFloat = 300
    private static let gap: CGFloat = 14

    var body: some View {
        GeometryReader { window in
            ScrollView {
                widgets
                    .frame(maxWidth: 880)
                    .padding(.horizontal, 44)
                    .padding(.top, 58)
                    .padding(.bottom, navigationClearance)
                    // Centred in the space above the navigation while it fits.
                    .frame(maxWidth: .infinity, minHeight: window.size.height)
            }
        }
        .task(id: status.address) {
            if status.address != nil { await home.watch() }
        }
        .confirmationDialog("Stop Home Assistant?", isPresented: $confirmingStop, titleVisibility: .visible) {
            StopButton()
            Button("Keep it running", role: .cancel) {}
        } message: {
            Text("It shuts down cleanly. Automations do not run until you start it again.")
        }
    }

    private var widgets: some View {
            VStack(spacing: Self.gap) {
                HStack(alignment: .top, spacing: Self.gap) {
                    PowerWidget(
                        status: status,
                        install: install,
                        selectedVersion: $selectedVersion,
                        showConsole: showConsole,
                        askToStop: { confirmingStop = true }
                    )
                    Group {
                        if status.address != nil {
                            ResourcesWidget(sample: home.samples.last, host: home.system?.host)
                        } else {
                            MachineWidget(settings: settings)
                        }
                    }
                    .frame(width: Self.sideWidth)
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: Self.gap) {
                    AppsWidget(address: status.address, home: home, showApps: showApps)
                    UpdatesWidget(isRunning: status.address != nil, home: home, showUpdates: showUpdates)
                        .frame(width: Self.sideWidth)
                }
                .fixedSize(horizontal: false, vertical: true)

                if status.bridgeUnavailable {
                    Caution(text: "The connection helper could not be installed, so this is Home Assistant's own address. Onboarding and the dashboard may fail to load until the machine can reach Docker Hub. Start again once it can.")
                }
                if status.address != nil, let advice = HealthAdvice.text(for: home.system?.unhealthy ?? []) {
                    Caution(text: advice, offersRestart: HealthAdvice.restartClears(home.system?.unhealthy ?? []))
                }
            }
    }
}

private struct StopButton: View {
    @Environment(\.windowActions) private var actions

    var body: some View {
        Button("Stop", action: actions.stop)
    }
}

// MARK: - Widget

/// One glass widget: an optional title, then its content, filling the height
/// its row gives it.
private struct Widget<Content: View>: View {
    var title: String?
    var interactive = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.ui(12, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(in: Corner.shape(Corner.surface), interactive: interactive)
    }
}

// MARK: - Power

private struct PowerWidget: View {
    let status: MachineStatus
    let install: InstallOptions
    @Binding var selectedVersion: String?
    let showConsole: () -> Void
    let askToStop: () -> Void
    @Environment(\.windowActions) private var actions

    var body: some View {
        Widget {
            HStack(alignment: .center, spacing: 16) {
                PowerKey(mode: keyMode, action: keyAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Home Assistant")
                        .font(.ui(12, .medium))
                        .foregroundStyle(Theme.secondary)
                    Text(StateDescription.word(for: status.state, hasDisk: status.hasDisk))
                        .font(.ui(30, .semibold))
                        .tracking(-0.9)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            detail
            Spacer(minLength: 0)
            controls
        }
    }

    private var keyMode: PowerKey.Mode {
        switch status.state {
        case .ready, .stopped: status.hasDisk ? .off : .install
        case .starting, .stopping: .busy
        case .running: .on
        case .failed: status.isActive ? .busy : .failed
        }
    }

    private var keyAction: (() -> Void)? {
        switch status.state {
        case .ready, .stopped: actions.start
        case .running: askToStop
        case .failed: status.isActive ? nil : actions.start
        case .starting, .stopping: nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch status.state {
        case .running(let url):
            VStack(alignment: .leading, spacing: 2) {
                AddressLine(label: status.sharedAddress == nil ? nil : "This Mac", url: url)
                if let shared = status.sharedAddress {
                    AddressLine(label: "Your network", url: shared)
                }
            }
        case .starting(let stage):
            BootProgress(current: stage, status: status)
        case .failed(let message):
            HStack(alignment: .top, spacing: 6) {
                Text(message)
                    .font(.mono(12))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                CopyButton(text: message, help: "Copy error")
            }
        case .ready, .stopped, .stopping:
            Text(caption)
                .font(.ui(13))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What pressing the key will do, or what is happening now.
    private var caption: String {
        if case .stopping = status.state { return "Shutting down cleanly." }
        if !status.hasDisk {
            return "Installing downloads Home Assistant OS, about 350 MB, and sets it up. Allow 15 to 25 minutes."
        }
        return status.canResume
            ? "Press the power key to start. It picks up where it left off, in a few seconds."
            : "Press the power key to start. It takes about a minute, and keeps running after this window is closed."
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            switch status.state {
            case .running(let url):
                Button {
                    actions.open(url)
                } label: {
                    HStack(spacing: 7) {
                        GlyphView(glyph: .open, size: 14)
                        Text("Open Home Assistant")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            case .ready, .stopped:
                if !status.hasDisk {
                    if !install.releases.isEmpty {
                        VersionMenu(releases: install.releases, selectedVersion: $selectedVersion)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .glass(in: Corner.shape(Corner.control))
                    }
                    Button {
                        actions.start()
                    } label: {
                        HStack(spacing: 7) {
                            GlyphView(glyph: .download, size: 14)
                            Text("Install")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            case .starting, .stopping:
                Button("Force stop", action: actions.forceStop)
                    .buttonStyle(SecondaryButtonStyle())
            case .failed:
                if status.isActive {
                    Button("Force stop", action: actions.forceStop)
                        .buttonStyle(PrimaryButtonStyle())
                } else if status.offerBootRepair {
                    Button("Repair startup", action: actions.repairStartup)
                        .buttonStyle(PrimaryButtonStyle())
                }
                Button("Show console", action: showConsole)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// The large glass key at the top of the power widget. It starts and stops the
/// machine, and its glyph says what state the machine is in.
private struct PowerKey: View {
    enum Mode { case off, install, on, busy, failed }

    let mode: Mode
    /// What a press does. Nil while there is nothing to press for.
    let action: (() -> Void)?

    private static let shape = Corner.shape(22)

    var body: some View {
        Button {
            action?()
        } label: {
            Group {
                switch mode {
                case .busy: ProgressView().controlSize(.regular)
                case .install: GlyphView(glyph: .download, size: 34)
                case .failed: GlyphView(glyph: .warning, size: 34)
                case .on, .off: GlyphView(glyph: .power, size: 34, emphasis: mode == .on)
                }
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 72, height: 72)
            .glass(in: Self.shape, tint: mode == .on ? Theme.ink.opacity(0.14) : nil, interactive: action != nil)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(action != nil)
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        switch mode {
        case .off: "Start Home Assistant"
        case .install: "Install Home Assistant"
        case .on: "Stop Home Assistant"
        case .busy: "Working"
        case .failed: "Start again"
        }
    }
}

private struct AddressLine: View {
    let label: String?
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.ui(12))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 84, alignment: .leading)
            }
            Text(url.absoluteString)
                .font(.mono(13))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            CopyButton(text: url.absoluteString, help: "Copy address")
        }
    }
}

// MARK: - Resources and machine

/// What the machine is using right now: a glyph, a figure and a bar each.
private struct ResourcesWidget: View {
    let sample: HomeAssistantStore.ResourceSample?
    let host: HostInfo?

    var body: some View {
        Widget(title: "Using now") {
            VStack(alignment: .leading, spacing: 16) {
                Gauge(
                    glyph: .processor,
                    label: "Processor",
                    value: sample?.processor.map { "\(Int(($0 * 100).rounded()))%" },
                    fraction: sample?.processor
                )
                Gauge(
                    glyph: .memory,
                    label: "Memory",
                    value: sample.map { "\(Self.gigabytes($0.memoryUsedBytes)) of \(Self.gigabytes($0.memoryTotalBytes)) GB" },
                    fraction: sample?.memory
                )
                Gauge(glyph: .disk, label: "Disk", value: disk, fraction: diskFraction)
            }
        }
    }

    private var disk: String? {
        guard let used = host?.diskUsed, let total = host?.diskTotal else { return nil }
        return "\(used.formatted(.number.precision(.fractionLength(1)))) of \(Int(total.rounded())) GB"
    }

    private var diskFraction: Double? {
        guard let used = host?.diskUsed, let total = host?.diskTotal, total > 0 else { return nil }
        return used / total
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))
    }
}

private struct Gauge: View {
    let glyph: Glyph
    let label: String
    let value: String?
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                GlyphView(glyph: glyph, size: 17)
                    .foregroundStyle(Theme.ink)
                Text(label)
                    .font(.ui(12))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                Text(value ?? "Reading")
                    .font(.ui(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Theme.faint : Theme.ink)
                    .lineLimit(1)
            }
            Bar(fraction: fraction ?? 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the machine is made of, while it is off.
private struct MachineWidget: View {
    let settings: VMSettings

    var body: some View {
        Widget(title: "This machine") {
            VStack(alignment: .leading, spacing: 15) {
                fact(.memory, "Memory", "\(settings.memoryGB) GB")
                fact(.processor, "Processor", "\(settings.cpuCount) cores")
                fact(.network, "Reachable from", network)
            }
        }
    }

    private var network: String {
        if settings.bridgedNetworking { return "Your network" }
        return settings.shareOnNetwork ? "Your network" : "This Mac"
    }

    private func fact(_ glyph: Glyph, _ label: String, _ value: String) -> some View {
        HStack(spacing: 9) {
            GlyphView(glyph: glyph, size: 17)
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(.ui(12))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.ui(13, .semibold))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Apps and updates

/// The installed apps as icons to open, and a way to add more.
private struct AppsWidget: View {
    let address: URL?
    @ObservedObject var home: HomeAssistantStore
    let showApps: () -> Void
    @Environment(\.windowActions) private var actions

    var body: some View {
        Widget(title: "Apps") {
            if let address {
                if home.hasLoadedApps {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(home.apps.prefix(4)) { app in
                            tile(app, address)
                        }
                        Button(action: showApps) {
                            VStack(spacing: 7) {
                                GlyphView(glyph: .plus, size: 20)
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 46, height: 46)
                                    .background(Theme.fill, in: Corner.shape(14))
                                    .overlay(Corner.shape(14).strokeBorder(Theme.hairline, lineWidth: 1))
                                Text(home.apps.isEmpty ? "Add apps" : "More")
                                    .font(.ui(11))
                                    .foregroundStyle(Theme.secondary)
                            }
                            .frame(width: 70)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Find and manage apps")
                    }
                } else {
                    Placeholder(text: "Reading your apps", isLoading: true)
                }
            } else {
                Text("Your apps appear here while Home Assistant runs.")
                    .font(.ui(12))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private func tile(_ app: InstalledApp, _ address: URL) -> some View {
        let page = home.appDetails[app.slug].flatMap {
            AppWebPage.url(slug: app.slug, detail: $0, homeAssistant: address)
        }
        return Button {
            if app.isRunning, let page { actions.open(page) } else { showApps() }
        } label: {
            VStack(spacing: 7) {
                AppArtwork(url: AppWebPage.iconURL(slug: app.slug, homeAssistant: address), size: 46)
                    .opacity(app.isRunning ? 1 : 0.45)
                Text(app.name)
                    .font(.ui(11))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.isRunning && page != nil ? "Open \(app.name)" : "\(app.name) is stopped. Manage it in Apps.")
    }
}

/// How many updates are waiting, leading to the list of them.
private struct UpdatesWidget: View {
    let isRunning: Bool
    @ObservedObject var home: HomeAssistantStore
    let showUpdates: () -> Void

    var body: some View {
        Button(action: showUpdates) {
            Widget(title: "Updates", interactive: isRunning) {
                if !isRunning {
                    Text("Checked while Home Assistant runs.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.faint)
                } else if home.system == nil {
                    Placeholder(text: "Checking", isLoading: true)
                } else {
                    let updates = home.updates
                    HStack(alignment: .center, spacing: 12) {
                        GlyphView(glyph: updates.isEmpty ? .check : .updates, size: 30, emphasis: !updates.isEmpty)
                            .foregroundStyle(Theme.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(updates.isEmpty ? "Up to date" : "\(updates.count) waiting")
                                .font(.ui(20, .semibold))
                                .tracking(-0.4)
                                .foregroundStyle(Theme.ink)
                            if !updates.isEmpty {
                                Text(updates.map(\.name).joined(separator: ", "))
                                    .font(.ui(12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        GlyphView(glyph: .chevronRight, size: 14)
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isRunning)
        .help("Show versions and updates")
    }
}

/// Something the user should know about and act on, on a strip of glass.
private struct Caution: View {
    let text: String
    /// Whether restarting the machine is the remedy, offered as a button.
    var offersRestart = false

    @State private var confirmingRestart = false
    @Environment(\.windowActions) private var actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GlyphView(glyph: .warning, size: 18)
                .foregroundStyle(Theme.ink)
            Text(text)
                .font(.ui(12))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if offersRestart {
                Button("Restart now") { confirmingRestart = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .glass(in: Corner.shape(Corner.surface))
        .confirmationDialog("Restart Home Assistant?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Restart", action: actions.restart)
            Button("Not now", role: .cancel) {}
        } message: {
            Text("It shuts down cleanly and starts again, which takes about a minute. Automations pause meanwhile.")
        }
    }
}

struct VersionMenu: View {
    let releases: [HAOSRelease]
    @Binding var selectedVersion: String?
    @Environment(\.windowActions) private var actions

    var body: some View {
        Menu {
            ForEach(releases) { release in
                Button {
                    selectedVersion = release.version
                } label: {
                    if selected?.version == release.version {
                        Label(release.version, systemImage: "checkmark")
                    } else {
                        Text(release.version)
                    }
                }
            }
            if let selected, let notes = selected.notesURL {
                Divider()
                Button("Release notes for \(selected.version)") { actions.open(notes) }
            }
        } label: {
            Text("Version \(selected?.version ?? "latest")")
                .font(.ui(12, .medium))
                .foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which Home Assistant OS release to install")
    }

    private var selected: HAOSRelease? {
        releases.first { $0.version == selectedVersion } ?? releases.first
    }
}

// MARK: - Starting

/// How far a start has come: one segment per stage, the stage's name, and
/// what it is waiting for.
private struct BootProgress: View {
    let current: BootStage
    let status: MachineStatus

    private var stages: [BootStage] {
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                ForEach(stages, id: \.ordinal) { stage in
                    Rectangle()
                        .fill(color(for: stage))
                        .frame(width: 44, height: 3)
                }
            }
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(current.title)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Theme.ink)
                if let startedAt = status.bootStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: startedAt, to: context.date))
                            .font(.ui(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            if let note {
                Text(note)
                    .font(.ui(12))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400, alignment: .leading)
            }
        }
    }

    private func color(for stage: BootStage) -> Color {
        if stage.ordinal < current.ordinal { return Theme.ink }
        if stage.ordinal == current.ordinal { return Theme.faint }
        return Theme.hairline
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }

    private var note: String? {
        switch current {
        case .downloadingImage(let percent):
            if let percent {
                "Fetching the official image, \(percent)% done."
            } else {
                "Looking up the latest official image, about 350 MB."
            }
        case .preparingDisk:
            "Unpacking the image into a working disk."
        case .waitingForHomeAssistant(let percent):
            if let download = status.download {
                "Downloading \(download.component) \(download.version). Home Assistant starts once its downloads finish."
            } else if status.guestOffline {
                "Home Assistant reports no internet connection. Check that this Mac is online; it retries on its own."
            } else if let percent, status.downloadRegressed {
                "Downloading Home Assistant, \(percent)% done. The connection dropped and the download restarted."
            } else if let percent {
                "Downloading Home Assistant, \(percent)% done."
            } else if status.freshInstall {
                "Downloading Home Assistant. This can take 10 to 20 minutes."
            } else {
                "Home Assistant is starting up. This usually takes about a minute."
            }
        case .connectingBridge:
            "Setting up the connection your browser needs to reach it."
        default:
            nil
        }
    }
}

