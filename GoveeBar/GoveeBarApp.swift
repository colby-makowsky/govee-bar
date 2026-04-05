import SwiftUI

@main
struct GoveeBarApp: App {
    @State private var stateManager = LightStateManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(stateManager: stateManager)
        } label: {
            MenuBarIcon(stateManager: stateManager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(stateManager: stateManager)
        }
    }
}

/// Dedicated view for the menu bar icon that explicitly observes state changes.
struct MenuBarIcon: View {
    var stateManager: LightStateManager

    var body: some View {
        Image(iconName)
            .renderingMode(.template)
    }

    private var deviceAvailable: Bool {
        guard let id = stateManager.selectedDeviceID else { return false }
        return stateManager.devices.contains { $0.id == id }
    }

    private var iconName: String {
        guard deviceAvailable else { return "MenuBarIconDisabled" }
        if stateManager.lightsOn { return "MenuBarIconOn" }
        if !stateManager.displayConnected { return "MenuBarIconDisabled" }
        return "MenuBarIconOff"
    }
}
