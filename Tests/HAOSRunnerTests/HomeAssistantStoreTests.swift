import XCTest
@testable import HAOSRunner

/// Requirement: the Apps screen shows what is really installed, an action the
/// user takes is carried out and reflected in the list, and a refusal is
/// explained.
@MainActor
final class HomeAssistantStoreTests: XCTestCase {
    /// A pretend guest with one installed app that answers the app's commands.
    private final class Guest {
        var appState = "started"
        var commands: [String] = []
        var refusal: String?

        var apps: String {
            #"{"result":"ok","data":{"addons":[{"name":"Tailscale","slug":"a0d7b954_tailscale","description":"Zero config VPN","version":"0.29.0","version_latest":"0.30.0","update_available":true,"state":"\#(appState)"}]}}"#
        }

        func answer(_ command: String) -> String {
            commands.append(command)
            if command == GuestCommand.apps { return apps }
            if command.hasPrefix("ha apps info") {
                return #"{"result":"ok","data":{"ingress":true,"webui":null}}"#
            }
            if command == GuestCommand.store {
                return #"{"result":"ok","data":{"addons":[{"name":"Mosquitto broker","slug":"core_mosquitto","description":"MQTT broker","version_latest":"6.5.2","installed":false,"available":true}]}}"#
            }
            if command == GuestCommand.system {
                return [
                    #"{"result":"ok","data":{"supervisor":"2026.11.0","homeassistant":"2026.9.0","hassos":"18.2"}}"#,
                    #"{"result":"ok","data":{"disk_total":62.3,"disk_used":5.5}}"#,
                    #"{"result":"ok","data":{"available_updates":[{"update_type":"core","version_latest":"2026.11.1"}]}}"#,
                    #"{"result":"ok","data":{"unhealthy":[]}}"#,
                ].joined(separator: "\n")
            }
            if command == GuestCommand.backups { return #"{"result":"ok","data":{"backups":[]}}"# }
            if command == GuestCommand.jobs { return #"{"result":"ok","data":{"jobs":[]}}"# }
            if command.hasPrefix("( ( ha apps stop") {
                if refusal == nil { appState = "stopped" }
                return ""
            }
            if command.hasPrefix("if [ -f") {
                if let refusal { return "exit=1\n{\"result\":\"error\",\"message\":\"\(refusal)\"}" }
                return "exit=0\n{\"result\":\"ok\",\"data\":{}}"
            }
            return ""
        }
    }

    private func makeStore(_ guest: Guest) -> HomeAssistantStore {
        HomeAssistantStore(client: SupervisorClient(
            send: { command, _ in guest.answer(command) },
            pollInterval: .milliseconds(1)
        ))
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "the store never reached the expected state")
    }

    func testConnectingLoadsInstalledAppsSystemAndUpdates() async throws {
        let store = makeStore(Guest())
        store.connect(to: URL(string: "http://192.168.64.22:9999/")!)
        try await wait { store.hasLoadedApps && store.system != nil && store.hasLoadedBackups }

        XCTAssertEqual(store.apps.map(\.name), ["Tailscale"])
        XCTAssertEqual(store.appDetails["a0d7b954_tailscale"], AppDetail(ingress: true, webui: nil))
        XCTAssertEqual(store.updates.map(\.name), ["Home Assistant Core", "Tailscale"])
    }

    func testStoppingAnAppRunsTheCommandAndShowsTheNewState() async throws {
        let guest = Guest()
        let store = makeStore(guest)
        store.connect(to: URL(string: "http://192.168.64.22:9999/")!)
        try await wait { store.hasLoadedApps }

        store.perform(.stop, slug: "a0d7b954_tailscale", name: "Tailscale")
        XCTAssertEqual(store.activity(for: "a0d7b954_tailscale")?.title, "Stopping")
        try await wait { store.activity(for: "a0d7b954_tailscale") == nil && store.apps.first?.isRunning == false }

        XCTAssertTrue(guest.commands.contains { $0.contains("ha apps stop a0d7b954_tailscale --raw-json") })
    }

    func testRefusedActionTellsTheUserWhy() async throws {
        let guest = Guest()
        guest.refusal = "App is protected"
        let store = makeStore(guest)
        var failures: [String] = []
        store.onFailure = { failures.append($0) }
        store.connect(to: URL(string: "http://192.168.64.22:9999/")!)
        try await wait { store.hasLoadedApps }

        store.perform(.stop, slug: "a0d7b954_tailscale", name: "Tailscale")
        try await wait { !failures.isEmpty }

        XCTAssertEqual(failures, ["Could not stop Tailscale. App is protected"])
        XCTAssertNil(store.activity(for: "a0d7b954_tailscale"))
    }

    /// Requirement: when Home Assistant refuses because it calls itself
    /// unhealthy, the message points to where the fix is.
    func testRefusalForAnUnhealthySystemPointsToHome() async throws {
        let guest = Guest()
        guest.refusal = "'AppManager.update' blocked from execution, system is not healthy - data_filesystem_check_error"
        let store = makeStore(guest)
        var failures: [String] = []
        store.onFailure = { failures.append($0) }
        store.connect(to: URL(string: "http://192.168.64.22:9999/")!)
        try await wait { store.hasLoadedApps }

        store.perform(.stop, slug: "a0d7b954_tailscale", name: "Tailscale")
        try await wait { !failures.isEmpty }

        XCTAssertEqual(failures.first?.hasSuffix("Home explains how to fix this."), true, failures.first ?? "")
    }

    func testStoreListsOnlyAppsThatAreNotInstalled() async throws {
        let store = makeStore(Guest())
        store.connect(to: URL(string: "http://192.168.64.22:9999/")!)
        await store.refreshStore()
        XCTAssertEqual(store.availableApps.map(\.slug), ["core_mosquitto"])
    }

    func testSwitchingTheMachineOffClearsWhatWasShown() async throws {
        let store = makeStore(Guest())
        store.connect(to: URL(string: "http://192.168.64.22:9999/")!)
        try await wait { store.hasLoadedApps }

        store.disconnect()

        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertNil(store.system)
        XCTAssertFalse(store.isConnected)
    }
}
