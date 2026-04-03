import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var stateManager: LightStateManager
    @AppStorage("automaticControl") private var automaticControl = true
    @State private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                automaticControl: $automaticControl,
                stateManager: stateManager
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
            .tag("general")

            DeviceSettingsView(stateManager: stateManager)
                .tabItem {
                    Label("Devices", systemImage: "wifi")
                }
                .tag("devices")

            ConnectionSettingsView(stateManager: stateManager)
                .tabItem {
                    Label("Connection", systemImage: "network")
                }
                .tag("connection")
        }
        .frame(width: 500, height: 320)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Binding var automaticControl: Bool
    @ObservedObject var stateManager: LightStateManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsRow("Startup:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch Govee Bar at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                    Text("App starts automatically when you log in")
                        .settingsCaption()
                }
            }

            settingsRow("Automation:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Automatic light control", isOn: $automaticControl)
                        .onChange(of: automaticControl) { _, newValue in
                            stateManager.automaticControlEnabled = newValue
                        }
                    Text("Turns lights on/off based on display and lock state")
                        .settingsCaption()
                }
            }

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
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
            // Revert toggle to actual system state
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Device Settings

struct DeviceSettingsView: View {
    @ObservedObject var stateManager: LightStateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsRow("Devices:") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            Task { await stateManager.discoverDevices() }
                        } label: {
                            Text(stateManager.isDiscovering ? "Scanning..." : "Discover Devices")
                        }
                        .disabled(stateManager.isDiscovering)

                        if stateManager.isDiscovering {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer()

                        Text("\(stateManager.devices.count) found")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    if stateManager.devices.isEmpty {
                        Text("Make sure LAN control is enabled in the Govee Home app")
                            .settingsCaption()
                    } else {
                        ForEach(stateManager.devices) { device in
                            HStack(spacing: 8) {
                                Image(systemName: device.id == stateManager.selectedDeviceID
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(device.id == stateManager.selectedDeviceID
                                        ? .green : .secondary)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.displayName)
                                    Text("\(device.sku) • \(device.ip)")
                                        .settingsCaption()
                                }

                                Spacer()

                                if device.id != stateManager.selectedDeviceID {
                                    Button("Select") {
                                        stateManager.selectDevice(device.id)
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if let error = stateManager.lastError {
                settingsRow("") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Connection Settings

struct ConnectionSettingsView: View {
    @ObservedObject var stateManager: LightStateManager
    @State private var apiKeyInput = ""
    @State private var showAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsRow("Method:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $stateManager.controlMethod) {
                        ForEach(LightStateManager.ControlMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)

                    Text("LAN is fastest. Auto tries LAN first, then cloud.")
                        .settingsCaption()
                }
            }

            settingsRow("API Key:") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Group {
                            if showAPIKey {
                                TextField("Govee API Key", text: $apiKeyInput)
                            } else {
                                SecureField("Govee API Key", text: $apiKeyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showAPIKey ? "Hide API key" : "Show API key")
                    }

                    HStack(spacing: 8) {
                        Button("Save") {
                            guard !apiKeyInput.isEmpty else { return }
                            stateManager.setAPIKey(apiKeyInput)
                        }
                        .disabled(apiKeyInput.isEmpty)

                        if stateManager.hasAPIKey {
                            Button("Clear") {
                                stateManager.clearAPIKey()
                                apiKeyInput = ""
                            }

                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Saved")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }

                    Text("Required for cloud API fallback. Get yours at developer.govee.com")
                        .settingsCaption()
                }
            }

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if let key = stateManager.storedAPIKey() {
                apiKeyInput = key
            }
        }
    }
}

// MARK: - Layout Helpers

/// Creates a settings row with a right-aligned label and left-aligned content,
/// matching the native macOS System Settings / Amphetamine style.
private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Text(label)
            .font(.system(.body))
            .foregroundStyle(.primary)
            .frame(width: 90, alignment: .trailing)

        content()
    }
}

private extension Text {
    func settingsCaption() -> some View {
        self
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
