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
        Window("HAOS Runner", id: "main") {
            DashboardView()
                .environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 600)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarContent().environmentObject(controller)
        } label: {
            Image(systemName: menuBarSymbol)
        }
    }

    private var menuBarSymbol: String {
        switch controller.state {
        case .running: "house.fill"
        case .starting, .stopping: "house.badge.clock"
        case .failed: "house.slash"
        case .ready, .stopped: "house"
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var controller: Controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .running(let url) = controller.state {
            Button("Open Home Assistant") { NSWorkspace.shared.open(url) }
            Text(url.absoluteString)
            Divider()
        }
        Text(statusLine)
        Divider()
        Button(actionTitle, action: toggle)
            .disabled(controller.state.isBusy)
        Button("Show Window") { openWindow(id: "main") }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.state {
        case .ready: "Ready to start"
        case .starting(let stage): stage.title
        case .running: "Running"
        case .stopping: "Stopping…"
        case .stopped: "Stopped"
        case .failed: "Stopped on an error"
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
