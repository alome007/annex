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
                Button("Erase and start over") { confirmingErase = true }
                    .disabled(!controller.canErase)
                Text("Rebuilds the machine from the source image. Everything in the current one is lost.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
        .confirmationDialog(
            "Erase this machine and install again?",
            isPresented: $confirmingErase,
            titleVisibility: .visible
        ) {
            Button("Erase and start over", role: .destructive) { controller.eraseAndReinstall() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Home Assistant's configuration, history and settings in this machine are deleted.")
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
