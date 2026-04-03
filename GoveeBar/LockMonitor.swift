import Foundation
import AppKit

/// Monitors macOS screen lock/unlock and sleep/wake events.
final class LockMonitor {
    var onLockStateChanged: ((Bool) -> Void)?

    private var isMonitoring = false

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let dnc = DistributedNotificationCenter.default()

        dnc.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        dnc.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        let wsnc = NSWorkspace.shared.notificationCenter

        wsnc.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        wsnc.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        wsnc.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        wsnc.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        wsnc.addObserver(
            self,
            selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func screenDidLock() {
        DispatchQueue.main.async { [weak self] in
            self?.onLockStateChanged?(true)
        }
    }

    @objc private func screenDidUnlock() {
        DispatchQueue.main.async { [weak self] in
            self?.onLockStateChanged?(false)
        }
    }

    @objc private func systemWillSleep() {
        DispatchQueue.main.async { [weak self] in
            self?.onLockStateChanged?(true)
        }
    }

    @objc private func systemDidWake() {
        // On wake, the screen is typically locked — the unlock notification
        // will fire separately if/when the user authenticates. So we don't
        // set locked=false here; we let screenDidUnlock handle that.
    }

    @objc private func screensDidSleep() {
        DispatchQueue.main.async { [weak self] in
            self?.onLockStateChanged?(true)
        }
    }

    @objc private func screensDidWake() {
        // Same as systemDidWake — wait for unlock notification
    }

    @objc private func systemWillPowerOff() {
        DispatchQueue.main.async { [weak self] in
            self?.onLockStateChanged?(true)
        }
    }

    deinit {
        stop()
    }
}
