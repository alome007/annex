import AppKit
import SwiftUI

/// The window is plain black in dark mode and plain white in light mode. Type
/// and hairlines carry the content; Liquid Glass is kept for the things the
/// user operates, so that glass always means "this does something".
enum Theme {
    /// The window's own colour: white in light mode, black in dark.
    static let paper = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// Its opposite, for text and symbols.
    static let ink = dynamic(light: 0x000000, dark: 0xFFFFFF)
    static let secondary = ink.opacity(0.66)
    static let faint = ink.opacity(0.46)
    static let hairline = ink.opacity(0.12)
    /// A quiet tint for insets, hovered rows and the chosen segment.
    static let fill = ink.opacity(0.06)
    static let fillStrong = ink.opacity(0.16)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Corner radii: soft enough to read as glass, short of turning controls into
/// pills, so every control keeps a straight edge.
enum Corner {
    static let small: CGFloat = 10
    static let control: CGFloat = 13
    static let surface: CGFloat = 20
    static let bar: CGFloat = 24

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension Font {
    /// Geist, the interface typeface. Bundled with the app.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", fixedSize: size).weight(weight)
    }

    /// Geist Mono, for text that is literally machine text: addresses, the
    /// console and logs.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist Mono", fixedSize: size).weight(weight)
    }
}

// MARK: - Glass

extension View {
    /// Puts the view on Liquid Glass.
    ///
    /// - Parameters:
    ///   - tint: a wash for the glass itself, to make one control stand out.
    ///   - interactive: whether the glass reacts to the pointer, for controls.
    func glass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }
}

/// Liquid Glass arrived in macOS 26 and its SDK. The app still runs on, and is
/// still built by CI for, macOS 14, where a translucent material stands in.
private struct GlassSurface<Outline: Shape>: ViewModifier {
    let shape: Outline
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    private func material(_ content: Content) -> some View {
        content
            .background(tint ?? .clear, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Buttons

/// Reports whether the pointer is over a view, for hover feedback.
struct Hovering<Content: View>: View {
    @State private var isHovering = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(isHovering)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// The action a screen is about: brighter glass and a heavier label.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .glass(in: Corner.shape(Corner.control), tint: Theme.ink.opacity(0.16), interactive: true)
            .contentShape(Corner.shape(Corner.control))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Every other action that stands on its own.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .glass(in: Corner.shape(Corner.control), interactive: true)
            .contentShape(Corner.shape(Corner.control))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A small action at the end of a list row.
struct RowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .glass(in: Corner.shape(Corner.small), interactive: true)
            .contentShape(Corner.shape(Corner.small))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct IconButton: View {
    let glyph: Glyph
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Hovering { hovering in
                GlyphView(glyph: glyph, size: 15)
                    .foregroundStyle(hovering ? Theme.ink : Theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(hovering ? Theme.fillStrong : .clear, in: Corner.shape(Corner.small))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Copies text and shows a tick for a moment in place of the copy icon.
struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied = false

    var body: some View {
        IconButton(glyph: copied ? .check : .copy, help: help) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        }
        .disabled(text.isEmpty)
    }
}

/// The "more" menu at the end of a row.
struct RowMenu<Items: View>: View {
    let help: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            // Menu labels take an image, not a drawing.
            Image(nsImage: GlyphImage.template(.more, size: 16))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A row of choices on one bar of glass, with a lighter patch that slides to
/// the chosen one. The bottom navigation and the System sections both use it.
struct GlassSegments<Item: Hashable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item
    var radius: CGFloat = Corner.surface
    /// Command plus this key chooses the item, when given.
    var shortcut: (Item) -> KeyEquivalent? = { _ in nil }
    let title: (Item) -> String
    @ViewBuilder let label: (Item, Bool) -> Label
    @Namespace private var patch

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let chosen = selection == item
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selection = item }
                } label: {
                    label(item, chosen)
                        .foregroundStyle(chosen ? Theme.ink : Theme.secondary)
                        .background {
                            if chosen {
                                Corner.shape(radius - 4)
                                    .fill(Theme.fillStrong)
                                    .matchedGeometryEffect(id: "patch", in: patch)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(CommandShortcut(key: shortcut(item)))
                .help(title(item))
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(4)
        .glass(in: Corner.shape(radius))
    }
}

private struct CommandShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

/// A spinner with what is happening beside it, and how far along when known.
struct ActivityLabel: View {
    let activity: HomeAssistantStore.Activity

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.ui(12))
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
        }
    }

    private var text: String {
        guard let fraction = activity.fraction else { return activity.title }
        return "\(activity.title) \(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Structure

/// The left and right margin every screen shares.
let pageMargin: CGFloat = 56
/// How far content keeps clear of the floating navigation at the bottom.
let navigationClearance: CGFloat = 92

/// A thin bar filled to a share of its width.
struct Bar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(Theme.ink.opacity(0.85))
                    .frame(width: geometry.size.width * min(1, max(0.02, fraction)))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// A screen: an optional title, optional controls beside it, and its content,
/// all hung from the same left margin.
struct Page<Accessory: View, Content: View>: View {
    var title: String?
    /// False for screens that fill the window with one scrolling pane of their own.
    var scrolls = true
    /// Space above the header. Less when something else already sits on top.
    var topInset: CGFloat = 56
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    private static var columnWidth: CGFloat { 840 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.ui(32, .medium))
                        .tracking(-1.1)
                        .foregroundStyle(Theme.ink)
                }
                Spacer(minLength: 12)
                accessory
            }
            .frame(maxWidth: Self.columnWidth)
            .padding(.horizontal, pageMargin)
            .padding(.top, topInset)
            .padding(.bottom, 20)

            if scrolls {
                ScrollView {
                    content
                        .frame(maxWidth: Self.columnWidth, alignment: .leading)
                        .padding(.horizontal, pageMargin)
                        .padding(.bottom, navigationClearance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                content
                    .frame(maxWidth: Self.columnWidth)
                    .padding(.horizontal, pageMargin)
                    .padding(.bottom, navigationClearance)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Page where Accessory == EmptyView {
    init(title: String? = nil, scrolls: Bool = true, topInset: CGFloat = 56, @ViewBuilder content: () -> Content) {
        self.init(title: title, scrolls: scrolls, topInset: topInset, accessory: { EmptyView() }, content: content)
    }
}

/// A titled list, with room for one control on the title's line.
struct SectionBlock<Accessory: View, Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                accessory
            }
            .frame(minHeight: 28)
            if let note {
                Text(note)
                    .font(.ui(12))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.top, 2)
            }
            Hairline().padding(.top, 10)
            content
        }
    }
}

extension SectionBlock where Accessory == EmptyView {
    init(title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, accessory: { EmptyView() }, content: content)
    }
}

/// One line of a list: a tint under the pointer and a hairline underneath.
struct ListRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Hovering { hovering in
                HStack(spacing: 12) { content }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 8)
                    .background(hovering ? Theme.fill : .clear, in: Corner.shape(Corner.small))
                    .padding(.horizontal, -8)
            }
            Hairline()
        }
    }
}

/// A quiet line that says what goes here and, when there is one, what to do.
struct Placeholder: View {
    let text: String
    var isLoading = false

    var body: some View {
        HStack(spacing: 8) {
            if isLoading { ProgressView().controlSize(.small) }
            Text(text)
                .font(.ui(12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }
}

/// What a screen shows instead of its content while Home Assistant is off.
struct OfflineState: View {
    let message: String
    let status: MachineStatus
    @Environment(\.windowActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
                .font(.ui(13))
                .foregroundStyle(Theme.secondary)
            if !status.state.isBusy, !status.isActive {
                Button(status.hasDisk ? "Start Home Assistant" : "Install Home Assistant", action: actions.start)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            GlyphView(glyph: .search, size: 14)
                .foregroundStyle(Theme.faint)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10)
        .frame(width: 220, height: 30)
        .glass(in: Corner.shape(Corner.control))
    }
}

// MARK: - Words

enum StateDescription {
    /// The machine's state in a word or two, as the home screen sets it large.
    static func word(for state: VMState, hasDisk: Bool) -> String {
        switch state {
        case .ready: hasDisk ? "Ready" : "Not installed"
        case .starting: hasDisk ? "Starting" : "Installing"
        case .running: "Running"
        case .stopping: "Stopping"
        case .stopped: "Off"
        case .failed: "Needs attention"
        }
    }
}
