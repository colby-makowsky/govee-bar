import Foundation
import Combine
import os.log

/// Combines display and lock signals to determine desired light state.
/// In M2, this will be wired to the Govee LAN controller.
@MainActor
final class LightStateManager: ObservableObject {
    @Published private(set) var lightsOn = false
    @Published private(set) var displayConnected = false
    @Published private(set) var screenLocked = false
    @Published var automaticControlEnabled = true {
        didSet { evaluateState() }
    }

    private let displayMonitor = DisplayMonitor()
    private let lockMonitor = LockMonitor()
    private let logger = Logger(subsystem: "com.govee-bar", category: "state")

    /// Manual override — when set, ignores automatic control until the next
    /// automatic state change clears it.
    private var manualOverride: Bool?

    init() {
        displayMonitor.onDisplayChanged = { [weak self] connected in
            self?.handleDisplayChanged(connected)
        }

        lockMonitor.onLockStateChanged = { [weak self] locked in
            self?.handleLockChanged(locked)
        }

        displayMonitor.start()
        lockMonitor.start()
    }

    func toggleLights() {
        let newState = !lightsOn
        manualOverride = newState
        applyLightState(newState)
    }

    // MARK: - Event Handlers

    private func handleDisplayChanged(_ connected: Bool) {
        logger.info("Display connected: \(connected)")
        displayConnected = connected
        manualOverride = nil // Clear manual override on automatic state change
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

        // TODO: M2 — Send command to Govee light controller
        // For now, just log the state change
    }
}
