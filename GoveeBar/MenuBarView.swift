import SwiftUI

struct MenuBarView: View {
    @ObservedObject var stateManager: LightStateManager

    var body: some View {
        Button {
            stateManager.toggleLights()
        } label: {
            Text(stateManager.lightsOn ? "Turn Lights Off" : "Turn Lights On")
        }
        .keyboardShortcut("t", modifiers: .command)

        Divider()

        Text("Studio Display: \(stateManager.displayConnected ? "Connected" : "Not Connected")")
        Text("Lights: \(stateManager.lightsOn ? "On" : "Off")")
        Text("Screen: \(stateManager.screenLocked ? "Locked" : "Unlocked")")

        Divider()

        SettingsLink {
            Text("Settings...")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Govee Bar") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
