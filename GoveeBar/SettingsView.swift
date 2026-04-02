import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var stateManager: LightStateManager
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("automaticControl") private var automaticControl = true

    var body: some View {
        TabView {
            GeneralSettingsView(
                launchAtLogin: $launchAtLogin,
                automaticControl: $automaticControl,
                stateManager: stateManager
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
        }
        .frame(width: 400, height: 200)
    }
}

struct GeneralSettingsView: View {
    @Binding var launchAtLogin: Bool
    @Binding var automaticControl: Bool
    @ObservedObject var stateManager: LightStateManager

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }

            Toggle("Automatic light control", isOn: $automaticControl)
                .onChange(of: automaticControl) { _, newValue in
                    stateManager.automaticControlEnabled = newValue
                }
        }
        .padding()
        .onAppear {
            stateManager.automaticControlEnabled = automaticControl
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }
}
