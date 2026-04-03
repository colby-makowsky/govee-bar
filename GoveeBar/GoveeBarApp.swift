import SwiftUI
import Combine

@main
struct GoveeBarApp: App {
    @StateObject private var stateManager = LightStateManager()

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
    @ObservedObject var stateManager: LightStateManager

    var body: some View {
        let name = iconName
        Image(name)
            .renderingMode(.template)
    }

    private var deviceAvailable: Bool {
        guard let id = stateManager.selectedDeviceID else { return false }
        return stateManager.devices.contains { $0.id == id }
    }

    private var iconName: String {
        if !stateManager.displayConnected || !deviceAvailable {
            return "MenuBarIconDisabled"
        } else if stateManager.lightsOn {
            return "MenuBarIconOn"
        } else {
            return "MenuBarIconOff"
        }
    }
}
