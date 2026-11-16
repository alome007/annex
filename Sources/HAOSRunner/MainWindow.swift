import AppKit
import SwiftUI

/// The three places the bottom navigation leads to.
enum Destination: String, CaseIterable {
    case home, apps, system

    var title: String {
        switch self {
        case .home: "Home"
        case .apps: "Apps"
        case .system: "System"
        }
    }

    var glyph: Glyph {
        switch self {
        case .home: .home
        case .apps: .apps
        case .system: .system
        }
    }
}

/// What the System screen holds.
enum SystemSection: String, CaseIterable {
    case updates, backups, logs, console, settings

    var title: String {
        switch self {
        case .updates: "Updates"
        case .backups: "Backups"
        case .logs: "Logs"
        case .console: "Console"
        case .settings: "Settings"
        }
    }
}

/// Everything the window can ask the app to do.
struct WindowActions {
    var start: () -> Void = {}
    var stop: () -> Void = {}
    var restart: () -> Void = {}
    var forceStop: () -> Void = {}
    var repairStartup: () -> Void = {}
    var open: (URL) -> Void = { _ in }
    var sendConsoleCommand: (String) -> Void = { _ in }
    var clearConsole: () -> Void = {}
    var takeSnapshot: () -> Void = {}
    var restoreSnapshot: (DiskSnapshot) -> Void = { _ in }
    var deleteSnapshot: (DiskSnapshot) -> Void = { _ in }
    var setOpensAtLogin: (Bool) -> Void = { _ in }
    var chooseSourceImage: () -> Void = {}
    var useAutomaticImage: () -> Void = {}
    var erase: (_ deletingDownloadedImage: Bool) -> Void = { _ in }
}

private struct WindowActionsKey: EnvironmentKey {
    static let defaultValue = WindowActions()
}

extension EnvironmentValues {
    var windowActions: WindowActions {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

/// Facts about this Mac and the install that the settings and buttons need.
struct InstallOptions: Equatable {
    var releases: [HAOSRelease] = []
    /// The file name of an image the user picked, or nil for the automatic download.
    var sourceImageName: String?
    var canErase = false
    var hasDownloadedImage = false
    var opensAtLogin = false
    var canManageSnapshots = false
    /// The interface bridged networking would use, or nil when this Mac offers none.
    var bridgedInterfaceName: String?
}

/// What the console screen shows.
struct ConsoleContent: Equatable {
    var lines: [ConsoleLine] = []
    var isAttached = false
}

/// The whole window, drawn from plain values and the two stores: one screen
/// on a plain black or white ground, and a bar of glass floating over its
/// bottom edge that the screen's content passes under.
struct WindowLayout: View {
    @Binding var destination: Destination
    /// Which part of the System screen is showing.
    @Binding var section: SystemSection
    let status: MachineStatus
    @ObservedObject var home: HomeAssistantStore
    @ObservedObject var snapshots: SnapshotLibrary
    let console: ConsoleContent
    let install: InstallOptions
    @Binding var settings: VMSettings
    @Binding var selectedVersion: String?
    @Binding var notice: String?
    @State private var logSource: LogSource = .core

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.paper
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            navigation
                .padding(.bottom, 18)
        }
        .overlay(alignment: .bottom) {
            if let notice {
                NoticeToast(text: notice) { self.notice = nil }
                    .padding(.bottom, navigationClearance - 8)
                    .padding(.horizontal, pageMargin)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var screen: some View {
        switch destination {
        case .home:
            HomeScreen(
                status: status,
                home: home,
                install: install,
                settings: settings,
                selectedVersion: $selectedVersion,
                showConsole: {
                    section = .console
                    destination = .system
                },
                showUpdates: {
                    section = .updates
                    destination = .system
                },
                showApps: { destination = .apps }
            )
        case .apps:
            AppsScreen(status: status, home: home) { source in
                logSource = source
                section = .logs
                destination = .system
            }
        case .system:
            SystemScreen(
                section: $section,
                logSource: $logSource,
                status: status,
                home: home,
                snapshots: snapshots,
                console: console,
                install: install,
                settings: $settings,
                selectedVersion: $selectedVersion
            )
        }
    }

    private var navigation: some View {
        let appUpdates = home.apps.filter(\.updateAvailable).count
        return GlassSegments(
            items: Destination.allCases,
            selection: $destination,
            radius: Corner.bar,
            shortcut: { item in
                Destination.allCases.firstIndex(of: item).flatMap { "\($0 + 1)".first }.map { KeyEquivalent($0) }
            },
            title: { item in
                item == .apps && appUpdates > 0
                    ? "Apps, \(appUpdates) \(appUpdates == 1 ? "update" : "updates") available"
                    : item.title
            }
        ) { item, chosen in
            HStack(spacing: 8) {
                GlyphView(glyph: item.glyph, size: 20, emphasis: chosen)
                    .frame(width: 24)
                    .overlay(alignment: .topTrailing) {
                        if item == .apps, appUpdates > 0 {
                            Circle().fill(Theme.ink).frame(width: 6, height: 6).offset(x: 3, y: -3)
                        }
                    }
                if chosen {
                    Text(item.title).font(.ui(13, .semibold))
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 42)
        }
    }
}

/// Backups, logs, the console and settings behind one row of sections.
private struct SystemScreen: View {
    @Binding var section: SystemSection
    @Binding var logSource: LogSource
    let status: MachineStatus
    @ObservedObject var home: HomeAssistantStore
    @ObservedObject var snapshots: SnapshotLibrary
    let console: ConsoleContent
    let install: InstallOptions
    @Binding var settings: VMSettings
    @Binding var selectedVersion: String?

    var body: some View {
        VStack(spacing: 0) {
            GlassSegments(
                items: SystemSection.allCases,
                selection: $section,
                title: \.title
            ) { item, chosen in
                Text(item.title)
                    .font(.ui(13, chosen ? .semibold : .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 28)
            }
            .padding(.top, 52)
            .padding(.horizontal, pageMargin)
            .frame(maxWidth: .infinity, alignment: .leading)

            switch section {
            case .updates:
                UpdatesScreen(status: status, home: home)
            case .backups:
                BackupsScreen(status: status, home: home, snapshots: snapshots, install: install)
            case .logs:
                LogsScreen(status: status, home: home, source: $logSource)
            case .console:
                ConsoleScreen(console: console)
            case .settings:
                SettingsScreen(settings: $settings, status: status, install: install, selectedVersion: $selectedVersion)
            }
        }
    }
}

/// A failure, floating just above the navigation until it is dismissed.
private struct NoticeToast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            GlyphView(glyph: .warning, size: 16)
                .foregroundStyle(Theme.ink)
            Text(text)
                .font(.ui(12, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
            IconButton(glyph: .close, help: "Dismiss", action: dismiss)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glass(in: Corner.shape(Corner.surface))
    }
}

/// Binds the window to the running app.
struct MainWindow: View {
    @EnvironmentObject private var controller: Controller
    @ObservedObject private var console = SerialConsole.shared
    @State private var destination: Destination = .home
    @State private var section: SystemSection = .updates

    var body: some View {
        WindowLayout(
            destination: $destination,
            section: $section,
            status: controller.status,
            home: controller.home,
            snapshots: controller.snapshots,
            console: ConsoleContent(lines: console.lines, isAttached: console.isAttached),
            install: InstallOptions(
                releases: controller.availableReleases,
                sourceImageName: Paths.sourceImage?.lastPathComponent,
                canErase: controller.canErase,
                hasDownloadedImage: controller.hasDownloadedImage,
                opensAtLogin: controller.opensAtLogin,
                canManageSnapshots: controller.canManageSnapshots,
                bridgedInterfaceName: VMSettings.bridgedInterface?.localizedDisplayName
            ),
            settings: $controller.settings,
            selectedVersion: $controller.selectedVersion,
            notice: $controller.notice
        )
        .environment(\.windowActions, actions)
        .frame(minWidth: 840, minHeight: 560)
        .task { controller.refreshReleases() }
        .onChange(of: controller.state) { _, state in
            if case .failed = state { destination = .home }
        }
    }

    private var actions: WindowActions {
        WindowActions(
            start: controller.start,
            stop: controller.stop,
            restart: controller.restart,
            forceStop: controller.forceStop,
            repairStartup: controller.repairAndRestart,
            open: { NSWorkspace.shared.open($0) },
            sendConsoleCommand: controller.sendConsoleCommand,
            clearConsole: console.clear,
            takeSnapshot: controller.takeSnapshot,
            restoreSnapshot: controller.restoreSnapshot,
            deleteSnapshot: controller.deleteSnapshot,
            setOpensAtLogin: controller.setOpensAtLogin,
            chooseSourceImage: { ImagePicker.chooseSourceImage(controller: controller) },
            useAutomaticImage: {
                Paths.sourceImage = nil
                controller.noteSettingsChanged()
            },
            erase: controller.erase
        )
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
