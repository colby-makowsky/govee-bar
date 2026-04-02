import Foundation

/// Monitors macOS screen lock/unlock events via DistributedNotificationCenter.
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
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        DistributedNotificationCenter.default().removeObserver(self)
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

    deinit {
        stop()
    }
}
