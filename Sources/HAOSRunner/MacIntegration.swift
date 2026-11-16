import AppKit
import ServiceManagement
import UserNotifications

/// Whether macOS opens the app when the user logs in.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
enum Notifier {
    /// Notifications belong to an app bundle. A bare binary run from the build
    /// folder has none, and asking for the notification centre there crashes.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    /// Asks macOS for permission to notify. Returns whether it was granted.
    static func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Posts a notification, unless the app is in front and the user can
    /// already see what happened.
    static func post(title: String, body: String) {
        guard let center, !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
