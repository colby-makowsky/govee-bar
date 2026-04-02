import SwiftUI

@main
struct GoveeBarApp: App {
    @StateObject private var stateManager = LightStateManager()

    private var menuBarIconName: String {
        if !stateManager.displayConnected {
            return "MenuBarIconDisabled"
        } else if stateManager.lightsOn {
            return "MenuBarIconOn"
        } else {
            return "MenuBarIconOff"
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(stateManager: stateManager)
        } label: {
            Image(menuBarIconName)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(stateManager: stateManager)
        }
    }
}
