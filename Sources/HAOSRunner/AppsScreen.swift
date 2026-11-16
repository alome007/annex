import SwiftUI

/// Installed apps with their live state, and the store to install more from.
struct AppsScreen: View {
    let status: MachineStatus
    @ObservedObject var home: HomeAssistantStore
    /// Opens the Logs screen on an app's log.
    let showLog: (LogSource) -> Void

    @State private var query = ""
    @State private var uninstalling: InstalledApp?
    @Environment(\.windowActions) private var actions

    var body: some View {
        Page(title: "Apps") {
            if status.address != nil {
                SearchField(prompt: "Search apps", text: $query)
            }
        } content: {
            if let address = status.address {
                VStack(alignment: .leading, spacing: 34) {
                    installed(address)
                    store(address)
                }
                .task {
                    await home.refreshApps()
                    await home.refreshStore()
                }
            } else {
                OfflineState(message: "Apps are installed and managed while Home Assistant is running.", status: status)
            }
        }
        .confirmationDialog(
            uninstalling.map { "Uninstall \($0.name)?" } ?? "",
            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
            titleVisibility: .visible,
            presenting: uninstalling
        ) { app in
            Button("Uninstall", role: .destructive) {
                home.perform(.uninstall, slug: app.slug, name: app.name)
            }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("The app and its data are removed from Home Assistant. This cannot be undone.")
        }
    }

    private func matches(_ name: String, _ description: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle) || description.localizedCaseInsensitiveContains(needle)
    }

    // MARK: Installed

    private func installed(_ address: URL) -> some View {
        let apps = home.apps.filter { matches($0.name, $0.description) }
        return SectionBlock(title: "Installed") {
            if !home.hasLoadedApps {
                Placeholder(text: "Reading installed apps", isLoading: true)
            } else if home.apps.isEmpty {
                Placeholder(text: "Nothing installed yet. Pick an app from the store below.")
            } else if apps.isEmpty {
                Placeholder(text: "No installed app matches \"\(query)\".")
            } else {
                ForEach(apps) { app in
                    ListRow {
                        AppArtwork(url: AppWebPage.iconURL(slug: app.slug, homeAssistant: address))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(app.name)
                                    .font(.ui(13, .medium))
                                    .foregroundStyle(Theme.ink)
                                AppStateLabel(state: app.state)
                            }
                            Text(app.description)
                                .font(.ui(12))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let activity = home.activity(for: app.slug) {
                            ActivityLabel(activity: activity)
                        } else {
                            installedControls(app, address)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func installedControls(_ app: InstalledApp, _ address: URL) -> some View {
        let page = home.appDetails[app.slug].flatMap {
            AppWebPage.url(slug: app.slug, detail: $0, homeAssistant: address)
        }
        if let version = app.version {
            Text(version)
                .font(.ui(12))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
        }
        if app.updateAvailable, let latest = app.versionLatest {
            Button("Update to \(latest)") { home.perform(.update, slug: app.slug, name: app.name) }
                .buttonStyle(RowButtonStyle())
        }
        if app.isRunning, let page {
            Button("Open") { actions.open(page) }
                .buttonStyle(RowButtonStyle())
                .help("Open \(app.name) in the browser")
        } else if !app.isRunning {
            Button("Start") { home.perform(.start, slug: app.slug, name: app.name) }
                .buttonStyle(RowButtonStyle())
        }
        RowMenu(help: "More actions for \(app.name)") {
            if app.isRunning {
                Button("Stop") { home.perform(.stop, slug: app.slug, name: app.name) }
                Button("Restart") { home.perform(.restart, slug: app.slug, name: app.name) }
            }
            Button("Show log") { showLog(.app(slug: app.slug, name: app.name)) }
            Button("Configure in Home Assistant") {
                actions.open(AppWebPage.settingsURL(slug: app.slug, homeAssistant: address))
            }
            Divider()
            Button("Uninstall…", role: .destructive) { uninstalling = app }
        }
    }

    // MARK: Store

    private func store(_ address: URL) -> some View {
        let available = home.availableApps
        let apps = available.filter { matches($0.name, $0.description) }
        return SectionBlock(
            title: "Store",
            note: home.hasLoadedStore ? "\(available.count) apps from the repositories set up in Home Assistant." : nil
        ) {
            if !home.hasLoadedStore {
                Placeholder(text: "Reading the store", isLoading: true)
            } else if apps.isEmpty {
                Placeholder(text: query.isEmpty ? "Everything in the store is installed." : "No store app matches \"\(query)\".")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        ListRow {
                            AppArtwork(url: AppWebPage.iconURL(slug: app.slug, homeAssistant: address))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name)
                                    .font(.ui(13, .medium))
                                    .foregroundStyle(Theme.ink)
                                Text(app.description)
                                    .font(.ui(12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let activity = home.activity(for: app.slug) {
                                ActivityLabel(activity: activity)
                            } else if app.available {
                                Button("Install") { home.perform(.install, slug: app.slug, name: app.name) }
                                    .buttonStyle(RowButtonStyle())
                                    .help("Install \(app.name)")
                            } else {
                                Text("Not available for this machine")
                                    .font(.ui(12))
                                    .foregroundStyle(Theme.faint)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AppStateLabel: View {
    let state: String

    var body: some View {
        HStack(spacing: 6) {
            marker
            Text(word)
                .font(.ui(12))
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var word: String {
        switch state {
        case "started": "Running"
        case "stopped": "Stopped"
        case "startup": "Starting"
        case "error": "Failed"
        default: "Unknown"
        }
    }

    /// A filled dot is running and a hollow one is not: shape, since the
    /// interface has no colour to say it with.
    @ViewBuilder private var marker: some View {
        switch state {
        case "started":
            Circle().fill(Theme.ink).frame(width: 7, height: 7)
        case "error":
            GlyphView(glyph: .warning, size: 12).foregroundStyle(Theme.ink)
        case "startup":
            Circle().strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: 1.4, dash: [2, 1.6])).frame(width: 8, height: 8)
        default:
            Circle().strokeBorder(Theme.faint, lineWidth: 1.4).frame(width: 8, height: 8)
        }
    }
}

/// An app's own icon, served by Home Assistant without signing in.
struct AppArtwork: View {
    let url: URL
    var size: CGFloat = 34

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).scaledToFit()
            } else {
                GlyphView(glyph: .package, size: size * 0.5)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Corner.shape(size * 0.28))
        .accessibilityHidden(true)
    }
}
