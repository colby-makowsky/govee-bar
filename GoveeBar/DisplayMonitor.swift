import Foundation
import CoreGraphics
import AppKit

/// Monitors for Apple Studio Display connection/disconnection events.
final class DisplayMonitor {
    /// Apple's USB vendor ID
    private static let appleVendorID: UInt32 = 0x610

    var onDisplayChanged: ((Bool) -> Void)?

    private var isMonitoring = false

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo else { return }
            let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // Only react once the reconfiguration is complete
            if flags.contains(.setMainFlag) || flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
                if !flags.contains(.beginConfigurationFlag) {
                    DispatchQueue.main.async {
                        monitor.checkDisplayState()
                    }
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        checkDisplayState()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        CGDisplayRemoveReconfigurationCallback({ _, _, _ in }, nil)
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

            // Apple Studio Display has vendor ID 0x610 (Apple) and is an external display
            if vendorID == appleVendorID && CGDisplayIsBuiltin(displayID) == 0 {
                return true
            }
        }

        return false
    }
}

