import AppKit
import SwiftUI

struct SettingsButton: View {
    @EnvironmentObject private var controller: Controller
    @State private var showing = false

    var body: some View {
        IconButton(symbol: "gearshape", help: "Machine settings") {
            showing.toggle()
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            SettingsView().environmentObject(controller)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: Controller
    @State private var confirmingErase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(value: $controller.settings.memoryGB, in: VMSettings.memoryRange) {
                    LabeledValue(label: "Memory", value: "\(controller.settings.memoryGB) GB")
                }
                Stepper(value: $controller.settings.cpuCount, in: VMSettings.cpuRange) {
                    LabeledValue(label: "Processor cores", value: "\(controller.settings.cpuCount)")
                }
            }
            Text("Changes apply the next time the machine starts.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)

            Toggle("Start Home Assistant when the app opens", isOn: $controller.settings.startOnLaunch)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Source image")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                HStack(spacing: 8) {
                    Text(sourceName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Paths.sourceImage == nil ? Theme.faint : Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if Paths.sourceImage != nil {
                        Button("Use automatic") {
                            Paths.sourceImage = nil
                            controller.noteSettingsChanged()
                        }
                    }
                    Button("Choose…") { ImagePicker.chooseSourceImage(controller: controller) }
                }
                if Paths.sourceImage == nil {
                    HStack {
                        Text("Version to install")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        if controller.availableReleases.isEmpty {
                            Text("Checking…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                        } else {
                            VersionMenu()
                        }
                    }
                }
                Button("Erase and start over") { confirmingErase = true }
                    .disabled(!controller.canErase)
                Text("Deletes this machine and returns to the install screen, where you can pick a version. Everything in the current machine is lost.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
        .task { controller.refreshReleases() }
        .confirmationDialog(
            "Erase this machine?",
            isPresented: $confirmingErase,
            titleVisibility: .visible
        ) {
            Button("Erase", role: .destructive) {
                controller.erase(deletingDownloadedImage: false)
            }
            if controller.hasDownloadedImage {
                Button("Erase and re-download the image", role: .destructive) {
                    controller.erase(deletingDownloadedImage: true)
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Home Assistant's configuration, history and settings in this machine are deleted. You return to the install screen, where you can pick a version.")
        }
    }

    private var sourceName: String { Paths.sourceImage?.lastPathComponent ?? "Automatic (latest official image)" }
}

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondary)
        }
        .frame(width: 200)
    }
}
