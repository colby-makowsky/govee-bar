import SwiftUI

struct MenuBarView: View {
    var stateManager: LightStateManager
    @Environment(\.openSettings) private var openSettings

    private var deviceName: String {
        if let deviceID = stateManager.selectedDeviceID,
           let device = stateManager.devices.first(where: { $0.id == deviceID }) {
            return device.displayName
        }
        return "None"
    }

    var body: some View {
        Button {
            stateManager.toggleLights()
        } label: {
            Text(stateManager.lightsOn ? "Turn Lights Off" : "Turn Lights On")
        }

        Divider()

        Text("Studio Display: \(stateManager.displayConnected ? "Connected" : "Not Connected")")
        Text("Lights: \(stateManager.lightsOn ? "On" : "Off")")
        Text("Screen: \(stateManager.screenLocked ? "Locked" : "Unlocked")")
        Text("Device: \(deviceName)")

        Divider()

        Button {
            Task {
                await stateManager.discoverDevices()
            }
        } label: {
            Text(stateManager.isDiscovering ? "Discovering..." : "Discover Devices")
        }
        .disabled(stateManager.isDiscovering)

        // Always show Select Device menu to keep stable item count
        Menu("Select Device") {
            if stateManager.devices.isEmpty {
                Text("No devices found")
            } else {
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

        Button("Settings...") {
            // Set dock icon from SF Symbol
            if let symbol = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Govee Bar") {
                let config = NSImage.SymbolConfiguration(pointSize: 128, weight: .regular)
                NSApp.applicationIconImage = symbol.withSymbolConfiguration(config) ?? symbol
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openSettings()

            // Bring existing settings window to front
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                for window in NSApp.windows where window.isVisible && window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        Divider()

        Button("Quit Govee Bar") {
            NSApplication.shared.terminate(nil)
        }
    }
}
