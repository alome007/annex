import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Controller.shared.machineIsActive else { return .terminateNow }
        Controller.shared.shutdownForQuit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct HAOSRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = Controller.shared

    var body: some Scene {
        Window("Annex", id: "main") {
            MainWindow()
                .environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 660)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarContent(home: controller.home)
                .environmentObject(controller)
        } label: {
            Image(nsImage: menuBarImage)
        }
    }

    private var menuBarImage: NSImage {
        switch controller.state {
        case .running: GlyphImage.template(.home, size: 17, emphasis: true)
        case .starting, .stopping: GlyphImage.template(.power, size: 17)
        case .failed: GlyphImage.template(.warning, size: 17)
        case .ready, .stopped: GlyphImage.template(.home, size: 17)
        }
    }
}

/// Status, the address, installed apps and start or stop, without the window.
private struct MenuBarContent: View {
    @EnvironmentObject private var controller: Controller
    @ObservedObject var home: HomeAssistantStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if case .running(let url) = controller.state {
            Divider()
            Button("Open Home Assistant") { NSWorkspace.shared.open(url) }
            Button("Copy Address") { copy(url.absoluteString) }
            if let shared = controller.sharedAddress {
                Button("Copy Network Address") { copy(shared.absoluteString) }
            }
            if !home.apps.isEmpty {
                Menu("Apps") {
                    ForEach(home.apps) { app in
                        appMenu(app, homeAssistant: url)
                    }
                }
            }
            if !home.updates.isEmpty {
                Text(home.updates.count == 1 ? "1 update available" : "\(home.updates.count) updates available")
            }
        }
        Divider()
        Button(actionTitle, action: toggle)
            .disabled(controller.state.isBusy)
        Button("Show Window") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private func appMenu(_ app: InstalledApp, homeAssistant: URL) -> some View {
        let page = home.appDetails[app.slug].flatMap {
            AppWebPage.url(slug: app.slug, detail: $0, homeAssistant: homeAssistant)
        }
        Menu(app.isRunning ? app.name : "\(app.name) (stopped)") {
            if app.isRunning {
                if let page {
                    Button("Open") { NSWorkspace.shared.open(page) }
                }
                Button("Restart") { home.perform(.restart, slug: app.slug, name: app.name) }
                Button("Stop") { home.perform(.stop, slug: app.slug, name: app.name) }
            } else {
                Button("Start") { home.perform(.start, slug: app.slug, name: app.name) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var statusLine: String {
        switch controller.state {
        case .starting(let stage): stage.title
        case .failed: "Stopped on an error"
        default: StateDescription.word(for: controller.state, hasDisk: controller.hasDisk)
        }
    }

    private var actionTitle: String {
        if case .running = controller.state { return "Stop Home Assistant" }
        return "Start Home Assistant"
    }

    private func toggle() {
        if case .running = controller.state {
            controller.stop()
        } else {
            controller.start()
        }
    }
}
