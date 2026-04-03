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
        didSet { if isReady { enforceDesiredState() } }
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
    private var statusPollTimer: Timer?

    /// True once initial discovery + status check is done.
    /// Prevents the state machine from acting before we know the real device state.
    private var isReady = false

    /// Tracks whether we're applying our own command, so we can ignore
    /// the resulting status echo from the device.
    private var isApplyingCommand = false

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

        // Set up event-driven status updates from LAN controller
        Task {
            await lanController.setStatusCallback { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.handleDeviceStatusUpdate(status)
                }
            }
        }

        // Start monitoring system events (updates displayConnected/screenLocked
        // but won't trigger commands until isReady)
        displayMonitor.start()
        lockMonitor.start()

        // Startup sequence: discover → get actual device state → enforce desired state
        Task {
            await discoverDevices()
            await syncInitialState()
            isReady = true
            enforceDesiredState()
            startPeriodicRediscovery()
            startStatusPolling()
        }
    }

    /// On startup, query the device for its actual state before making decisions.
    private func syncInitialState() async {
        guard let deviceID = selectedDeviceID,
              let device = devices.first(where: { $0.id == deviceID }) else { return }

        do {
            try await lanController.requestStatus(device: device)
            // Give the listener a moment to receive the response
            try? await Task.sleep(for: .seconds(1))
        } catch {
            logger.warning("Initial status check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Device Status (Event-Driven)

    private func handleDeviceStatusUpdate(_ status: GoveeLANController.DeviceStatus) {
        // Ignore echoes from our own commands
        guard !isApplyingCommand else { return }

        // Only react to status from the selected device
        guard let selectedID = selectedDeviceID,
              status.deviceId == selectedID else { return }

        if !isReady {
            // During init, just sync our state to match the device — no commands
            lightsOn = status.isOn
            logger.info("Initial device state: \(status.isOn ? "ON" : "OFF")")
        } else if status.isOn != lightsOn {
            logger.info("External state change detected: lights \(status.isOn ? "ON" : "OFF")")
            lightsOn = status.isOn
            manualOverride = status.isOn
        }
    }

    /// Periodically requests device status as a complement to event-driven updates.
    /// Some state changes may not trigger a broadcast, so this catches stragglers.
    private func startStatusPolling() {
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollDeviceStatus()
            }
        }
    }

    private func pollDeviceStatus() async {
        guard let deviceID = selectedDeviceID,
              let device = devices.first(where: { $0.id == deviceID }) else { return }

        do {
            // This sends a devStatus request; the response arrives at the
            // persistent listener and triggers handleDeviceStatusUpdate
            try await lanController.requestStatus(device: device)
        } catch {
            // Poll failures are expected occasionally, don't surface as errors
        }
    }

    // MARK: - API Key

    @Published private(set) var hasAPIKey: Bool = false

    private static let apiKeyDefaultsKey = "goveeAPIKey"

    func loadAPIKeyIfNeeded() {
        if let key = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !key.isEmpty {
            hasAPIKey = true
            Task { await cloudController.setAPIKey(key) }
        }
    }

    func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: Self.apiKeyDefaultsKey)
        hasAPIKey = true
        Task { await cloudController.setAPIKey(key) }
        lastError = nil
        logger.info("API key saved")
    }

    func clearAPIKey() {
        UserDefaults.standard.removeObject(forKey: Self.apiKeyDefaultsKey)
        hasAPIKey = false
        Task { await cloudController.setAPIKey(nil) }
        logger.info("API key cleared")
    }

    func storedAPIKey() -> String? {
        UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey)
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
        manualOverride = !lightsOn
        enforceDesiredState()
    }

    // MARK: - Event Handlers

    private func handleDisplayChanged(_ connected: Bool) {
        logger.info("Display connected: \(connected)")
        displayConnected = connected
        guard isReady else { return }
        manualOverride = nil
        enforceDesiredState()
    }

    private func handleLockChanged(_ locked: Bool) {
        logger.info("Screen locked: \(locked)")
        screenLocked = locked
        guard isReady else { return }
        manualOverride = nil
        enforceDesiredState()
    }

    // MARK: - State Evaluation

    /// Determines the desired light state and sends a command only if the
    /// device doesn't match. Called after events and on startup.
    private func enforceDesiredState() {
        let desired: Bool
        if let override = manualOverride {
            desired = override
        } else if automaticControlEnabled {
            desired = displayConnected && !screenLocked
        } else {
            return
        }

        guard lightsOn != desired else { return }

        lightsOn = desired
        logger.info("Lights → \(desired ? "ON" : "OFF")")
        Task {
            await sendLightCommand(on: desired)
        }
    }

    // MARK: - Command Dispatch

    private func sendLightCommand(on: Bool) async {
        guard let deviceID = selectedDeviceID,
              let device = devices.first(where: { $0.id == deviceID }) else {
            logger.warning("No device selected, skipping command")
            return
        }

        // Flag so we ignore the status echo from our own command
        isApplyingCommand = true
        defer {
            // Clear after a short delay to allow the echo to pass
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.isApplyingCommand = false
            }
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
        loadAPIKeyIfNeeded()
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
