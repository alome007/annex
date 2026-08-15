import Foundation

struct HAAddon: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let symbol: String
}

enum AppCatalog {
    static let popular: [HAAddon] = [
        HAAddon(
            id: "5c53de3b_esphome",
            name: "ESPHome",
            blurb: "Build and flash firmware for ESP devices",
            symbol: "cpu"
        ),
        HAAddon(
            id: "core_mosquitto",
            name: "Mosquitto broker",
            blurb: "MQTT message broker",
            symbol: "dot.radiowaves.left.and.right"
        ),
        HAAddon(
            id: "a0d7b954_nodered",
            name: "Node-RED",
            blurb: "Wire flows and automations visually",
            symbol: "point.3.connected.trianglepath.dotted"
        ),
        HAAddon(
            id: "core_configurator",
            name: "File editor",
            blurb: "Edit configuration files in the browser",
            symbol: "doc.text"
        ),
        HAAddon(
            id: "a0d7b954_vscode",
            name: "Studio Code Server",
            blurb: "Full VS Code, in the browser",
            symbol: "chevron.left.forwardslash.chevron.right"
        ),
    ]
}
