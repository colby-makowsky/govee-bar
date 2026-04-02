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

        if let deviceID = stateManager.selectedDeviceID,
           let device = stateManager.devices.first(where: { $0.id == deviceID }) {
            Text("Device: \(device.displayName)")
        } else {
            Text("Device: None")
        }

        Divider()

        Button {
            Task {
                await stateManager.discoverDevices()
            }
        } label: {
            Text(stateManager.isDiscovering ? "Discovering..." : "Discover Devices")
        }
        .disabled(stateManager.isDiscovering)

        if !stateManager.devices.isEmpty {
            Menu("Select Device") {
                ForEach(stateManager.devices) { device in
                    Button {
                        stateManager.selectDevice(device.id)
                    } label: {
                        let selected = device.id == stateManager.selectedDeviceID
                        Text("\(selected ? "✓ " : "")\(device.displayName)")
                    }
                }
            }
        }

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
