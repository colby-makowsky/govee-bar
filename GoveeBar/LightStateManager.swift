import Foundation
import Combine
import os.log

/// Combines display and lock signals to determine desired light state,
/// and sends commands to Govee devices via LAN.
@MainActor
final class LightStateManager: ObservableObject {
    @Published private(set) var lightsOn = false
    @Published private(set) var displayConnected = false
    @Published private(set) var screenLocked = false
    @Published private(set) var devices: [GoveeLANController.Device] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var isDiscovering = false

    @Published var automaticControlEnabled = true {
        didSet { evaluateState() }
    }

    private let displayMonitor = DisplayMonitor()
    private let lockMonitor = LockMonitor()
    private let lanController = GoveeLANController()
    private let logger = Logger(subsystem: "com.govee-bar", category: "state")

    /// Manual override — when set, ignores automatic control until the next
    /// automatic state change clears it.
    private var manualOverride: Bool?

    /// Timer for periodic device re-discovery
    private var rediscoveryTimer: Timer?

    init() {
        displayMonitor.onDisplayChanged = { [weak self] connected in
            self?.handleDisplayChanged(connected)
        }

        lockMonitor.onLockStateChanged = { [weak self] locked in
            self?.handleLockChanged(locked)
        }

        // Restore selected device from UserDefaults
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")

        displayMonitor.start()
        lockMonitor.start()

        // Discover devices on launch
        Task {
            await discoverDevices()
            startPeriodicRediscovery()
        }
    }

    // MARK: - Device Discovery

    func discoverDevices() async {
        isDiscovering = true
        defer { isDiscovering = false }

        do {
            let found = try await lanController.discoverDevices(timeout: 3.0)
            devices = found
            logger.info("Found \(found.count) device(s)")

            // Auto-select if only one device found and none selected
            if selectedDeviceID == nil, let first = found.first {
                selectDevice(first.id)
            }
        } catch {
            logger.error("Discovery failed: \(error.localizedDescription)")
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

    private func sendLightCommand(on: Bool) async {
        guard let deviceID = selectedDeviceID,
              let device = devices.first(where: { $0.id == deviceID }) else {
            logger.warning("No device selected, skipping command")
            return
        }

        do {
            if on {
                try await lanController.turnOn(device: device)
            } else {
                try await lanController.turnOff(device: device)
            }
        } catch {
            logger.error("Failed to \(on ? "turn on" : "turn off") lights: \(error.localizedDescription)")
            // TODO: M3 — Cloud API fallback
        }
    }
}
