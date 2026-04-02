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

            DeviceSettingsView(stateManager: stateManager)
                .tabItem {
                    Label("Devices", systemImage: "lightbulb.2")
                }
        }
        .frame(width: 450, height: 300)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Binding var launchAtLogin: Bool
    @Binding var automaticControl: Bool
    @ObservedObject var stateManager: LightStateManager

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Toggle("Automatic light control", isOn: $automaticControl)
                    .onChange(of: automaticControl) { _, newValue in
                        stateManager.automaticControlEnabled = newValue
                    }
            }

            Section {
                Picker("Control method", selection: $stateManager.controlMethod) {
                    ForEach(LightStateManager.ControlMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
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

// MARK: - Device Settings

struct DeviceSettingsView: View {
    @ObservedObject var stateManager: LightStateManager
    @State private var apiKeyInput = ""
    @State private var showAPIKey = false

    var body: some View {
        Form {
            Section("Govee API Key") {
                HStack {
                    if showAPIKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save") {
                        guard !apiKeyInput.isEmpty else { return }
                        stateManager.setAPIKey(apiKeyInput)
                    }
                    .disabled(apiKeyInput.isEmpty)

                    if stateManager.hasAPIKey {
                        Button("Clear", role: .destructive) {
                            stateManager.clearAPIKey()
                            apiKeyInput = ""
                        }

                        Text("Saved in Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Devices") {
                HStack {
                    Button {
                        Task { await stateManager.discoverDevices() }
                    } label: {
                        Text(stateManager.isDiscovering ? "Discovering..." : "Discover Devices")
                    }
                    .disabled(stateManager.isDiscovering)

                    Spacer()

                    Text("\(stateManager.devices.count) found")
                        .foregroundStyle(.secondary)
                }

                if stateManager.devices.isEmpty {
                    Text("No devices found. Make sure LAN control is enabled in the Govee app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stateManager.devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.displayName)
                                    .font(.body)
                                Text("\(device.sku) • \(device.ip)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if device.id == stateManager.selectedDeviceID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Select") {
                                    stateManager.selectDevice(device.id)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            if let error = stateManager.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .padding()
        .onAppear {
            if let key = KeychainHelper.loadAPIKey() {
                apiKeyInput = key
            }
        }
    }
}
