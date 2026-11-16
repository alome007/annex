import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import HAOSRunner

/// Photographs every screen from sample data, in light and dark, so the
/// interface can be looked at without starting a machine:
///
///     HAOS_SNAPSHOT_DIR=/tmp/haos-screens swift test --filter ScreenRenderTests
///
/// It checks nothing about the screens, and is skipped unless that folder is
/// named. A window comes to the front for under a minute while it runs.
@MainActor
final class ScreenRenderTests: XCTestCase {
    private static let size = CGSize(width: 980, height: 660)
    private static let address = URL(string: "http://192.168.64.22:9999/")!

    /// A pretend guest with a small, realistic Home Assistant in it.
    private final class SampleGuest {
        private var ticks = 0
        var unhealthy: [String] = []

        func answer(_ command: String) -> String {
            switch command {
            case GuestCommand.apps:
                return #"{"result":"ok","data":{"addons":[{"name":"Tailscale","slug":"a0d7b954_tailscale","description":"Zero config VPN for building secure networks","version":"0.29.0","version_latest":"0.30.0","update_available":true,"state":"started"},{"name":"Mosquitto broker","slug":"core_mosquitto","description":"An open source MQTT broker","version":"6.5.2","version_latest":"6.5.2","update_available":false,"state":"started"},{"name":"Node-RED","slug":"a0d7b954_nodered","description":"Flow-based programming for the Internet of Things","version":"20.1.0","version_latest":"20.1.0","update_available":false,"state":"stopped"}]}}"#
            case GuestCommand.store:
                let apps = [
                    ("ESPHome Device Builder", "5c53de3b_esphome", "Build your own smart home devices using ESPHome, no programming experience required", true),
                    ("File editor", "core_configurator", "Simple browser-based file editor for Home Assistant", true),
                    ("Matter Server", "core_matter_server", "Matter WebSocket Server for Home Assistant Matter support", true),
                    ("Music Assistant", "d5369777_music_assistant", "Music Assistant Server: your music, your players", true),
                    ("Samba share", "core_samba", "Expose Home Assistant folders with SMB/CIFS", true),
                    ("Studio Code Server", "a0d7b954_vscode", "Fully featured Visual Studio Code experience integrated in the Home Assistant frontend", true),
                    ("Whisper", "core_whisper", "Speech-to-text with Whisper", false),
                    ("Zigbee2MQTT", "45df7312_zigbee2mqtt", "Use your Zigbee devices without the vendor's bridge or gateway", true),
                ]
                let entries = apps.map { name, slug, description, available in
                    #"{"name":"\#(name)","slug":"\#(slug)","description":"\#(description)","version_latest":"1.0.0","installed":false,"available":\#(available)}"#
                }
                return #"{"result":"ok","data":{"addons":[\#(entries.joined(separator: ","))]}}"#
            case GuestCommand.system:
                return [
                    #"{"result":"ok","data":{"supervisor":"2026.11.0","homeassistant":"2026.9.0","hassos":"18.2"}}"#,
                    #"{"result":"ok","data":{"disk_total":62.3,"disk_used":5.5}}"#,
                    #"{"result":"ok","data":{"available_updates":[{"update_type":"core","version_latest":"2026.11.1"},{"update_type":"os","version_latest":"18.4"}]}}"#,
                    #"{"result":"ok","data":{"unhealthy":[\#(unhealthy.map { "\"\($0)\"" }.joined(separator: ","))]}}"#,
                ].joined(separator: "\n")
            case GuestCommand.backups:
                return #"{"result":"ok","data":{"backups":[{"slug":"a1b2c3d4","name":"Annex 14 Nov 2026 at 21:10","date":"2026-11-14T20:10:00+00:00","type":"full","size":212.4},{"slug":"e5f6a7b8","name":"Before the Core update","date":"2026-11-02T08:30:00+00:00","type":"partial","size":48.0}]}}"#
            case GuestCommand.resources:
                ticks += 1
                let wave = Int(180 + 140 * sin(Double(ticks) / 2.2) + 60 * sin(Double(ticks) * 1.7))
                let busy = 5000 + ticks * 40 + wave * ticks / 3
                let available = 2_900_000 - Int(250_000 * sin(Double(ticks) / 6))
                return "cpu  \(busy) 0 0 \(200_000 + ticks * 2000) 0 0 0 0 0 0\nMemTotal: 4005344 kB\nMemAvailable: \(available) kB"
            default:
                if command.hasPrefix("ha apps info") { return #"{"result":"ok","data":{"ingress":true,"webui":null}}"# }
                if command.hasPrefix("docker logs --tail 300 homeassistant") {
                    return [
                        "2026-11-14 22:04:31.118 INFO (MainThread) [homeassistant.setup] Setting up tailscale",
                        "2026-11-14 22:04:31.402 INFO (MainThread) [homeassistant.components.mqtt] Connected to MQTT server core-mosquitto:1883",
                        "2026-11-14 22:04:32.019 WARNING (MainThread) [homeassistant.components.sensor] Entity sensor.outdoor_temperature has no unit of measurement",
                        "2026-11-14 22:04:32.521 INFO (MainThread) [homeassistant.core] Starting Home Assistant",
                        "2026-11-14 22:04:33.870 ERROR (MainThread) [homeassistant.components.met] Retrying setup: timeout fetching forecast",
                        "2026-11-14 22:04:36.260 INFO (MainThread) [homeassistant.components.http] Serving on port 8123",
                    ].joined(separator: "\n")
                }
                return ""
            }
        }
    }

    private func registerFonts() {
        let fonts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Fonts")
        for name in ["Geist[wght].ttf", "GeistMono[wght].ttf"] {
            CTFontManagerRegisterFontsForURL(fonts.appending(path: name) as CFURL, .process, nil)
        }
    }

    /// Liquid Glass is drawn by the window server, so the screens are shown in
    /// a real window and photographed with `screencapture`. The window appears
    /// on screen while the test runs.
    private func photograph(_ window: NSWindow, to file: URL) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path(percentEncoded: false)]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0, "screencapture could not photograph the window")
    }

    func testRenderEveryScreen() async throws {
        guard let folder = ProcessInfo.processInfo.environment["HAOS_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set HAOS_SNAPSHOT_DIR to a folder to draw the screens into it.")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        registerFonts()

        let guest = SampleGuest()
        let home = HomeAssistantStore(client: SupervisorClient(send: { command, _ in guest.answer(command) }))
        home.connect(to: Self.address)
        try await Task.sleep(for: .milliseconds(200))
        await home.refreshStore()
        for _ in 0..<40 { await home.sampleResources() }
        await home.loadLog(.core)
        let offline = HomeAssistantStore(client: SupervisorClient(send: { _, _ in "" }))
        let ailingGuest = SampleGuest()
        ailingGuest.unhealthy = ["data_filesystem_check_error"]
        let ailing = HomeAssistantStore(client: SupervisorClient(send: { command, _ in ailingGuest.answer(command) }))
        ailing.connect(to: Self.address)
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<40 { await ailing.sampleResources() }

        let root = FileManager.default.temporaryDirectory.appending(path: "haosrunner-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = MachineFiles(
            disk: root.appending(path: "haos.img"),
            firmware: root.appending(path: "efi-vars.fd"),
            suspendedState: root.appending(path: "machine-state.vzvmsave"),
            snapshots: root.appending(path: "Snapshots")
        )
        try Data("disk".utf8).write(to: files.disk)
        _ = try SnapshotStore.take(named: "2 Nov 2026 at 08:14", suspendedSession: nil, files: files)
        try Data("memory".utf8).write(to: files.suspendedState)
        _ = try SnapshotStore.take(named: "14 Nov 2026 at 21:02", suspendedSession: "4gb-4cpu-nat", files: files)
        let snapshots = SnapshotLibrary(files: files)

        let running = MachineStatus(
            state: .running(url: Self.address),
            hasDisk: true,
            isActive: true,
            sharing: .listening(port: 8123),
            sharedAddress: URL(string: "http://192.168.1.24:8123/")
        )
        let starting = MachineStatus(
            state: .starting(.waitingForHomeAssistant(downloadPercent: nil)),
            hasDisk: true,
            isActive: true,
            bootStartedAt: Date.now.addingTimeInterval(-161),
            download: .init(component: "supervisor", version: "2026.11.0")
        )
        let failed = MachineStatus(
            state: .failed("Waiting for Home Assistant has not finished after 40 minutes. The console may show why. Force stop powers the machine off."),
            hasDisk: true,
            isActive: true
        )
        let consoleLines = [
            "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]",
            "[  OK  ] Started Docker Application Container Engine.",
            "Welcome to Home Assistant",
            "homeassistant login: root",
            "> ha core info",
            "# ha core info",
            "arch: aarch64",
            "version: 2026.9.0",
        ].enumerated().map { ConsoleLine(id: $0.offset, text: $0.element) }

        let off = MachineStatus(state: .stopped, hasDisk: true, canResume: true)
        let scenes: [(String, Destination, SystemSection, MachineStatus, HomeAssistantStore, String?)] = [
            ("home-running", .home, .backups, running, home, nil),
            ("home-unhealthy", .home, .backups, running, ailing, nil),
            ("home-starting", .home, .backups, starting, offline, nil),
            ("home-not-installed", .home, .backups, MachineStatus(), offline, nil),
            ("home-off", .home, .backups, off, offline, nil),
            ("home-failed", .home, .backups, failed, offline, nil),
            ("apps", .apps, .backups, running, home, nil),
            ("apps-off", .apps, .backups, off, offline, nil),
            ("system-updates", .system, .updates, running, home, nil),
            ("system-backups", .system, .backups, running, home, "Could not install Whisper. App is not available for this machine."),
            ("system-backups-off", .system, .backups, off, offline, nil),
            ("system-logs", .system, .logs, running, home, nil),
            ("system-console", .system, .console, running, home, nil),
            ("system-settings", .system, .settings, running, home, nil),
        ]

        NSApplication.shared.setActivationPolicy(.accessory)
        let frame = CGRect(origin: .zero, size: Self.size)
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        window.setContentSize(Self.size)
        window.center()
        // In front and active, as the app is when it is being used: glass and
        // controls draw differently in a window that is behind others.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        // HAOS_SNAPSHOT_ONLY=home-off,apps limits the run to those screens.
        let wanted = ProcessInfo.processInfo.environment["HAOS_SNAPSHOT_ONLY"]?
            .split(separator: ",").map(String.init)
        for (name, destination, section, status, store, notice) in scenes
        where wanted?.contains(name) ?? true {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                hosting.rootView = AnyView(WindowLayout(
                    destination: .constant(destination),
                    section: .constant(section),
                    status: status,
                    home: store,
                    snapshots: snapshots,
                    console: ConsoleContent(lines: consoleLines, isAttached: status.isActive),
                    install: InstallOptions(
                        releases: [HAOSRelease(
                            version: "18.4",
                            assetName: "haos_generic-aarch64-18.4.img.xz",
                            assetURL: Self.address,
                            notesURL: nil
                        )],
                        canErase: !status.isActive,
                        hasDownloadedImage: true,
                        canManageSnapshots: !status.isActive,
                        bridgedInterfaceName: "Wi-Fi"
                    ),
                    settings: .constant(VMSettings(shareOnNetwork: status.sharedAddress != nil)),
                    selectedVersion: .constant(nil),
                    notice: .constant(notice)
                )
                // A fixed size, as the app's own minimum size gives it. Left
                // free, the hosting view asks each screen how small it can be,
                // long text answers "one letter wide", and the window is
                // stretched thousands of points tall to fit.
                .frame(width: Self.size.width, height: Self.size.height))
                try await photograph(window, to: output.appending(path: "\(name)-\(suffix).png"))
            }
        }

        if wanted?.contains("glyphs") ?? true {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                hosting.rootView = AnyView(GlyphSheet().frame(width: Self.size.width, height: Self.size.height))
                try await photograph(window, to: output.appending(path: "glyphs-\(suffix).png"))
            }
        }
    }
}

/// Every glyph large and at the size the interface uses, to judge the set.
private struct GlyphSheet: View {
    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(130), spacing: 12), count: 6)
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(Glyph.allCases, id: \.self) { glyph in
                VStack(spacing: 10) {
                    HStack(spacing: 18) {
                        GlyphView(glyph: glyph, size: 56)
                        VStack(spacing: 10) {
                            GlyphView(glyph: glyph, size: 18)
                            GlyphView(glyph: glyph, size: 18, emphasis: true)
                        }
                    }
                    Text("\(glyph)")
                        .font(.ui(11))
                        .foregroundStyle(Theme.secondary)
                }
                .foregroundStyle(Theme.ink)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}
