import SwiftUI

@main
struct GoveeBarApp: App {
    @StateObject private var stateManager = LightStateManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(stateManager: stateManager)
        } label: {
            Image(systemName: stateManager.lightsOn ? "lightbulb.fill" : "lightbulb.slash")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(stateManager: stateManager)
        }
    }
}
