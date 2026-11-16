import SwiftUI

struct SettingsScreen: View {
    @Binding var settings: VMSettings
    let status: MachineStatus
    let install: InstallOptions
    @Binding var selectedVersion: String?

    @State private var confirmingErase = false
    @Environment(\.windowActions) private var actions

    var body: some View {
        Page(topInset: 20) {
            VStack(alignment: .leading, spacing: 34) {
                machine
                startup
                network
                image
                reset
            }
        }
        .confirmationDialog("Erase this machine?", isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { actions.erase(false) }
            if install.hasDownloadedImage {
                Button("Erase and download the image again", role: .destructive) { actions.erase(true) }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Home Assistant's configuration, history and apps in this machine are deleted. Disk snapshots are kept. You return to the install screen, where you can pick a version.")
        }
    }

    private var machine: some View {
        SectionBlock(title: "Machine", note: "Changes apply the next time the machine starts.") {
            SettingRow(title: "Memory") {
                Stepper(value: $settings.memoryGB, in: VMSettings.memoryRange) {
                    value("\(settings.memoryGB) GB")
                }
            }
            SettingRow(title: "Processor cores") {
                Stepper(value: $settings.cpuCount, in: VMSettings.cpuRange) {
                    value("\(settings.cpuCount)")
                }
            }
        }
    }

    private var startup: some View {
        SectionBlock(title: "Startup") {
            SettingRow(title: "Start Home Assistant when the app opens") {
                switchControl($settings.startOnLaunch)
            }
            SettingRow(title: "Open Annex when you log in") {
                switchControl(Binding(get: { install.opensAtLogin }, set: actions.setOpensAtLogin))
            }
            SettingRow(
                title: "Notify when Home Assistant starts or fails to",
                note: "Only while Annex is in the background."
            ) {
                switchControl($settings.notifications)
            }
        }
    }

    private var network: some View {
        SectionBlock(title: "Network") {
            SettingRow(
                title: "Reach Home Assistant from other devices",
                note: shareNote,
                noteColor: shareFailed ? Theme.ink : Theme.secondary
            ) {
                switchControl($settings.shareOnNetwork)
                    .disabled(settings.bridgedNetworking)
            }
            SettingRow(title: "Give Home Assistant its own address on your network", note: bridgedNote) {
                switchControl($settings.bridgedNetworking)
                    .disabled(install.bridgedInterfaceName == nil)
            }
        }
    }

    private var shareFailed: Bool {
        if case .failed = status.sharing { return true }
        return false
    }

    private var shareNote: String {
        if case .failed(let reason) = status.sharing {
            return "Sharing could not start. \(reason)"
        }
        if let shared = status.sharedAddress {
            return "Phones and other devices on your network can open \(shared.absoluteString). Anyone on the network can reach the sign-in page while this is on."
        }
        return "Forwards port \(VMSettings.sharePort) on this Mac to Home Assistant while it runs. Anyone on your network can then reach its sign-in page."
    }

    private var bridgedNote: String {
        guard let interface = install.bridgedInterfaceName else {
            return "Bridged networking is not available on this Mac."
        }
        return "Joins \(interface) directly so Home Assistant can discover devices. Needs a build signed with Apple's com.apple.vm.networking entitlement, which only paid developer accounts get; other builds will not start with this on."
    }

    private var image: some View {
        SectionBlock(title: "Image") {
            SettingRow(title: "Source image", note: install.sourceImageName ?? "Automatic: the official image, downloaded for you.") {
                if install.sourceImageName != nil {
                    Button("Use automatic", action: actions.useAutomaticImage)
                        .buttonStyle(RowButtonStyle())
                }
                Button("Choose…", action: actions.chooseSourceImage)
                    .buttonStyle(RowButtonStyle())
            }
            if install.sourceImageName == nil {
                SettingRow(title: "Version to install", note: "Used the next time the machine is installed.") {
                    if install.releases.isEmpty {
                        Text("Checking")
                            .font(.ui(12))
                            .foregroundStyle(Theme.faint)
                    } else {
                        VersionMenu(releases: install.releases, selectedVersion: $selectedVersion)
                    }
                }
            }
        }
    }

    private var reset: some View {
        SectionBlock(title: "Reset") {
            SettingRow(
                title: "Erase and start over",
                note: "Deletes this machine and returns to the install screen. Everything in the current machine is lost."
            ) {
                Button("Erase…") { confirmingErase = true }
                    .buttonStyle(RowButtonStyle())
                    .disabled(!install.canErase)
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.ui(13))
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            .frame(minWidth: 44, alignment: .trailing)
    }

    private func switchControl(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.secondary)
    }
}

/// A setting: what it is on the left, its control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var note: String?
    var noteColor: Color = Theme.secondary
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: note == nil ? .center : .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.ui(13))
                        .foregroundStyle(Theme.ink)
                    if let note {
                        Text(note)
                            .font(.ui(12))
                            .foregroundStyle(noteColor)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 480, alignment: .leading)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { control }
            }
            .padding(.vertical, 11)
            Hairline()
        }
        .accessibilityElement(children: .contain)
    }
}
