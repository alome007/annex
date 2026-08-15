import AppKit
import SwiftUI

enum Theme {
    static let page = dynamic(light: NSColor(hex: 0xFAFAFA), dark: NSColor(hex: 0x161618))
    static let inset = dynamic(light: NSColor(hex: 0xF0F0F1), dark: NSColor(hex: 0x1E1E21))
    static let ink = dynamic(light: NSColor(hex: 0x1A1A1C), dark: NSColor(hex: 0xF2F2F4))
    static let secondary = dynamic(light: NSColor(hex: 0x5C5C61), dark: NSColor(hex: 0xA6A6AD))
    static let faint = dynamic(light: NSColor(hex: 0x8E8E93), dark: NSColor(hex: 0x6E6E76))
    static let divider = dynamic(
        light: NSColor(hex: 0x000000, alpha: 0.10),
        dark: NSColor(hex: 0xFFFFFF, alpha: 0.12)
    )

    static let accent = dynamic(light: NSColor(hex: 0x0277BD), dark: NSColor(hex: 0x4FC3F7))

    static let buttonFill = dynamic(light: NSColor(hex: 0x1A1A1C), dark: NSColor(hex: 0xE8E8EA))
    static let buttonLabel = dynamic(light: NSColor(hex: 0xFAFAFA), dark: NSColor(hex: 0x1A1A1C))
    static let quietFill = dynamic(light: NSColor(hex: 0xEDEDEE), dark: NSColor(hex: 0x2A2A2E))

    static let running = dynamic(light: NSColor(hex: 0x2E7D32), dark: NSColor(hex: 0x66BB6A))
    static let warning = dynamic(light: NSColor(hex: 0xB26A00), dark: NSColor(hex: 0xFFB74D))
    static let error = dynamic(light: NSColor(hex: 0xC62828), dark: NSColor(hex: 0xEF5350))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.buttonLabel)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Theme.buttonFill)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(pressedOpacity(configuration))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private func pressedOpacity(_ configuration: Configuration) -> Double {
        guard isEnabled else { return 0.35 }
        return configuration.isPressed ? 0.8 : 1
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.quietFill)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint ?? Theme.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }
}

struct StatusDot: View {
    let state: VMState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(Text(label))
    }

    private var color: Color {
        switch state {
        case .running: Theme.running
        case .failed: Theme.error
        case .starting, .stopping: Theme.warning
        default: Theme.faint
        }
    }

    private var label: String {
        switch state {
        case .running: "Running"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .failed: "Error"
        default: "Off"
        }
    }
}

@MainActor
final class CopyFlash: ObservableObject {
    @Published private(set) var flashed = false

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashed = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            flashed = false
        }
    }
}

struct CopyIconButton: View {
    @ObservedObject var flash: CopyFlash
    let text: String
    var help = "Copy"

    var body: some View {
        IconButton(
            symbol: flash.flashed ? "checkmark" : "doc.on.doc",
            help: help,
            disabled: text.isEmpty,
            tint: flash.flashed ? Theme.running : nil
        ) {
            flash.copy(text)
        }
    }
}

enum StateDescription {
    static func headline(for state: VMState, hasDisk: Bool) -> String {
        switch state {
        case .ready: hasDisk ? "Ready to start" : "Ready to install"
        case .starting: hasDisk ? "Starting Home Assistant" : "Installing Home Assistant"
        case .running: "Running"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .failed: "Something went wrong"
        }
    }

    static func detail(for state: VMState, hasDisk: Bool) -> String {
        switch state {
        case .ready:
            hasDisk
                ? "Starts in about a minute. Home Assistant keeps running while the window is closed."
                : "Downloads Home Assistant OS (about 350 MB) and sets everything up. The whole install takes 15–25 minutes."
        case .starting:
            "You can watch the machine boot in the console below."
        case .running:
            "Home Assistant is running on this Mac."
        case .stopping:
            "Shutting the machine down cleanly."
        case .stopped:
            "The machine is off. Your configuration and apps are saved."
        case .failed(let message):
            message
        }
    }
}
