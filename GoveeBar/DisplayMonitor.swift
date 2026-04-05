import AppKit
import CoreGraphics
import Foundation

/// Monitors for Apple Studio Display connection/disconnection events.
final class DisplayMonitor {
    /// Apple's USB vendor ID
    private static let appleVendorID: UInt32 = 0x610

    var onDisplayChanged: ((Bool) -> Void)?

    private var isMonitoring = false

    deinit {
        stop()
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        checkDisplayState()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false

        // Must pass the same function pointer and context used during registration
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func checkDisplayState() {
        let connected = Self.isStudioDisplayConnected()
        onDisplayChanged?(connected)
    }

    static func isStudioDisplayConnected() -> Bool {
        let maxDisplays: UInt32 = 16
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        let err = CGGetOnlineDisplayList(maxDisplays, &onlineDisplays, &displayCount)
        guard err == .success else { return false }

        for i in 0..<Int(displayCount) {
            let displayID = onlineDisplays[i]
            let vendorID = CGDisplayVendorNumber(displayID)

            // Apple Studio Display has vendor ID 0x610 and is an external display
            if vendorID == appleVendorID && CGDisplayIsBuiltin(displayID) == 0 {
                return true
            }
        }

        return false
    }
}

/// File-level C-compatible callback. A global (context-free) function is required
/// so that the same pointer can be passed to both register and unregister calls.
private func displayReconfigurationCallback(
    _ displayID: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // Only react once the reconfiguration is complete
    guard !flags.contains(.beginConfigurationFlag) else { return }

    if flags.contains(.setMainFlag) || flags.contains(.addFlag) || flags.contains(.removeFlag) ||
       flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
        DispatchQueue.main.async {
            monitor.checkDisplayState()
        }
    }
}
