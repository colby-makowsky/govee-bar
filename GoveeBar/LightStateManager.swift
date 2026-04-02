import Foundation
import Combine
import os.log

/// Combines display and lock signals to determine desired light state,
/// and sends commands to Govee devices via LAN with cloud API fallback.
@MainActor
final class LightStateManager: ObservableObject {
    enum ControlMethod: String, CaseIterable {
        case lan = "LAN"
        case cloud = "Cloud API"
        case auto = "Auto (LAN → Cloud)"
    }

    @Published private(set) var lightsOn = false
    @Published private(set) var displayConnected = false
    @Published private(set) var screenLocked = false
    @Published private(set) var devices: [GoveeLANController.Device] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var isDiscovering = false
    @Published private(set) var lastError: String?

    @Published var automaticControlEnabled = true {
        didSet { evaluateState() }
    }

    @Published var controlMethod: ControlMethod = .auto {
        didSet {
            UserDefaults.standard.set(controlMethod.rawValue, forKey: "controlMethod")
        }
    }

    private let displayMonitor = DisplayMonitor()
    private let lockMonitor = LockMonitor()
    private let lanController = GoveeLANController()
    private let cloudController = GoveeCloudController()
    private let logger = Logger(subsystem: "com.govee-bar", category: "state")

    private var manualOverride: Bool?
    private var rediscoveryTimer: Timer?

    init() {
        displayMonitor.onDisplayChanged = { [weak self] connected in
            self?.handleDisplayChanged(connected)
        }

        lockMonitor.onLockStateChanged = { [weak self] locked in
            self?.handleLockChanged(locked)
        }

        // Restore preferences
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")
        if let saved = UserDefaults.standard.string(forKey: "controlMethod"),
           let method = ControlMethod(rawValue: saved) {
            controlMethod = method
        }

        // Load API key from Keychain
        Task {
            if let apiKey = KeychainHelper.loadAPIKey() {
                await cloudController.setAPIKey(apiKey)
            }
        }

        displayMonitor.start()
        lockMonitor.start()

        Task {
            await discoverDevices()
            startPeriodicRediscovery()
        }
    }

    // MARK: - API Key

    func setAPIKey(_ key: String) {
        do {
            try KeychainHelper.saveAPIKey(key)
            Task { await cloudController.setAPIKey(key) }
            lastError = nil
            logger.info("API key saved to Keychain")
        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to save API key: \(error.localizedDescription)")
        }
    }

    func clearAPIKey() {
        KeychainHelper.deleteAPIKey()
        Task { await cloudController.setAPIKey(nil) }
        logger.info("API key cleared")
    }

    var hasAPIKey: Bool {
        KeychainHelper.loadAPIKey() != nil
    }

    // MARK: - Device Discovery

    func discoverDevices() async {
        isDiscovering = true
        defer { isDiscovering = false }

        do {
            let found = try await lanController.discoverDevices(timeout: 3.0)
            devices = found
            lastError = nil
            logger.info("Found \(found.count) device(s)")

            if selectedDeviceID == nil, let first = found.first {
                selectDevice(first.id)
            }
        } catch {
            logger.error("Discovery failed: \(error.localizedDescription)")
            lastError = "Discovery failed: \(error.localizedDescription)"
        }
    }

    func selectDevice(_ id: String) {
        selectedDeviceID = id
        UserDefaults.standard.set(id, forKey: "selectedDeviceID")
        logger.info("Selected device: \(id)")
    }

    private func startPeriodicRediscovery() {
        rediscoveryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.discoverDevices()
            }
        }
    }

    // MARK: - Light Toggle

    func toggleLights() {
        let newState = !lightsOn
        manualOverride = newState
        applyLightState(newState)
    }

    // MARK: - Event Handlers

    private func handleDisplayChanged(_ connected: Bool) {
        logger.info("Display connected: \(connected)")
        displayConnected = connected
        manualOverride = nil
        evaluateState()
    }

    private func handleLockChanged(_ locked: Bool) {
        logger.info("Screen locked: \(locked)")
        screenLocked = locked
        manualOverride = nil
        evaluateState()
    }

    // MARK: - State Evaluation

    private func evaluateState() {
        if let override = manualOverride {
            applyLightState(override)
            return
        }

        guard automaticControlEnabled else { return }

        let shouldBeOn = displayConnected && !screenLocked
        applyLightState(shouldBeOn)
    }

    private func applyLightState(_ on: Bool) {
        guard lightsOn != on else { return }
        lightsOn = on
        logger.info("Lights → \(on ? "ON" : "OFF")")

        Task {
            await sendLightCommand(on: on)
        }
    }

    // MARK: - Command Dispatch

    private func sendLightCommand(on: Bool) async {
        guard let deviceID = selectedDeviceID,
              let device = devices.first(where: { $0.id == deviceID }) else {
            logger.warning("No device selected, skipping command")
            return
        }

        switch controlMethod {
        case .lan:
            await sendViaLAN(on: on, device: device)
        case .cloud:
            await sendViaCloud(on: on, device: device)
        case .auto:
            await sendViaLAN(on: on, device: device, cloudFallback: true)
        }
    }

    private func sendViaLAN(on: Bool, device: GoveeLANController.Device, cloudFallback: Bool = false) async {
        do {
            if on {
                try await lanController.turnOn(device: device)
            } else {
                try await lanController.turnOff(device: device)
            }
            lastError = nil
        } catch {
            logger.error("LAN failed: \(error.localizedDescription)")
            if cloudFallback {
                logger.info("Falling back to cloud API")
                await sendViaCloud(on: on, device: device)
            } else {
                lastError = "LAN: \(error.localizedDescription)"
            }
        }
    }

    private func sendViaCloud(on: Bool, device: GoveeLANController.Device) async {
        do {
            if on {
                try await cloudController.turnOn(sku: device.sku, device: device.id)
            } else {
                try await cloudController.turnOff(sku: device.sku, device: device.id)
            }
            lastError = nil
        } catch {
            logger.error("Cloud failed: \(error.localizedDescription)")
            lastError = "Cloud: \(error.localizedDescription)"
        }
    }
}
