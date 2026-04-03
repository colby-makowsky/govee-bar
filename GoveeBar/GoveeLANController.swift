import Foundation
import Network
import os.log

/// Controls Govee devices over the local network using UDP.
///
/// Discovery uses multicast (239.255.255.250:4001), devices respond on port 4002.
/// Commands are sent via unicast UDP to the device IP on port 4003.
///
/// A persistent listener on port 4002 catches both discovery responses and
/// unsolicited device state updates (e.g. external on/off toggles).
actor GoveeLANController {
    struct Device: Identifiable, Codable, Sendable {
        let id: String        // MAC-based device ID
        let ip: String
        let sku: String
        let deviceName: String?
        var lastSeen: Date

        var displayName: String {
            deviceName ?? "\(sku) (\(id))"
        }
    }

    struct DeviceStatus: Sendable {
        let deviceId: String
        let isOn: Bool
        let brightness: Int?
        let color: (r: Int, g: Int, b: Int)?
        let colorTemperature: Int?
    }

    private let logger = Logger(subsystem: "com.govee-bar", category: "lan")

    private let multicastGroup = "239.255.255.250"
    private let scanPort: UInt16 = 4001
    private let responsePort: UInt16 = 4002
    private let commandPort: UInt16 = 4003

    private var discoveredDevices: [String: Device] = [:]
    private var persistentListener: NWListener?

    /// Callback for discovery events
    var onDeviceDiscovered: ((Device) -> Void)?

    /// Callback for device state changes (from status responses or broadcasts)
    var onDeviceStatusUpdate: ((DeviceStatus) -> Void)?

    func setStatusCallback(_ callback: @escaping @Sendable (DeviceStatus) -> Void) {
        onDeviceStatusUpdate = callback
    }

    // MARK: - Persistent Listener

    /// Starts a persistent UDP listener on port 4002 that receives all
    /// device messages: discovery responses, status updates, and state broadcasts.
    func startListening() throws {
        guard persistentListener == nil else { return }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: responsePort)!)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleListenerState(state) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receiveMessages(on: connection)
        }

        listener.start(queue: .global())
        persistentListener = listener
        logger.info("Persistent UDP listener started on port \(self.responsePort)")
    }

    func stopListening() {
        persistentListener?.cancel()
        persistentListener = nil
        logger.info("Persistent UDP listener stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("UDP listener ready")
        case .failed(let error):
            logger.error("UDP listener failed: \(error.localizedDescription)")
            // Try to restart
            persistentListener = nil
            try? startListening()
        default:
            break
        }
    }

    private nonisolated func receiveMessages(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let content {
                Task {
                    await self.handleIncomingMessage(data: content)
                }
            }

            // Keep receiving on this connection
            if error == nil {
                self.receiveMessages(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - Message Handling

    private func handleIncomingMessage(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["msg"] as? [String: Any],
              let cmd = msg["cmd"] as? String else {
            return
        }

        logger.debug("Received message: cmd=\(cmd)")

        switch cmd {
        case "scan":
            handleScanResponse(msg: msg)
        case "devStatus":
            handleStatusMessage(msg: msg)
        default:
            logger.debug("Unhandled command: \(cmd)")
        }
    }

    private func handleScanResponse(msg: [String: Any]) {
        guard let responseData = msg["data"] as? [String: Any] else { return }

        let ip = responseData["ip"] as? String ?? ""
        let deviceId = responseData["device"] as? String ?? ""
        let sku = responseData["sku"] as? String ?? ""
        let deviceName = responseData["deviceName"] as? String

        guard !deviceId.isEmpty, !ip.isEmpty else { return }

        let device = Device(id: deviceId, ip: ip, sku: sku, deviceName: deviceName, lastSeen: Date())
        discoveredDevices[deviceId] = device
        logger.info("Discovered device: \(sku) at \(ip)")
        onDeviceDiscovered?(device)
    }

    private func handleStatusMessage(msg: [String: Any]) {
        guard let data = msg["data"] as? [String: Any] else { return }

        // The device ID comes from the scan data we cached, or from the message
        // Status messages include onOff, brightness, color, colorTemInKelvin
        let onOff = data["onOff"] as? Int
        let brightness = data["brightness"] as? Int
        let colorTemp = data["colorTemInKelvin"] as? Int

        var color: (Int, Int, Int)?
        if let colorData = data["color"] as? [String: Any],
           let r = colorData["r"] as? Int,
           let g = colorData["g"] as? Int,
           let b = colorData["b"] as? Int {
            color = (r, g, b)
        }

        // Try to identify which device this came from
        // Status responses don't always include device ID, so we match against
        // known devices. If only one device is known, use that.
        let deviceId: String
        if let id = data["device"] as? String {
            deviceId = id
        } else if discoveredDevices.count == 1, let first = discoveredDevices.keys.first {
            deviceId = first
        } else {
            logger.warning("Status update from unknown device, ignoring")
            return
        }

        if let isOn = onOff {
            let status = DeviceStatus(
                deviceId: deviceId,
                isOn: isOn == 1,
                brightness: brightness,
                color: color,
                colorTemperature: colorTemp
            )
            logger.info("Device \(deviceId) status: on=\(isOn == 1), brightness=\(brightness ?? -1)")
            onDeviceStatusUpdate?(status)
        }
    }

    // MARK: - Discovery

    /// Sends a multicast scan to discover devices.
    /// Responses are received by the persistent listener.
    /// Devices that haven't responded in 15 minutes are pruned.
    func discoverDevices(timeout: TimeInterval = 3.0) async throws -> [Device] {
        // Ensure listener is running
        try startListening()

        // Send scan command via multicast
        try await sendScanCommand()

        // Wait for responses to arrive at the persistent listener
        try await Task.sleep(for: .seconds(timeout))

        // Prune devices not seen in the last 15 minutes
        let staleThreshold = Date().addingTimeInterval(-900)
        discoveredDevices = discoveredDevices.filter { $0.value.lastSeen > staleThreshold }

        let devices = Array(discoveredDevices.values)
        logger.info("Discovered \(devices.count) device(s)")
        return devices
    }

    private func sendScanCommand() async throws {
        let scanMessage: [String: Any] = [
            "msg": [
                "cmd": "scan",
                "data": [
                    "account_topic": "reserve"
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: scanMessage)

        let connection = NWConnection(
            host: NWEndpoint.Host(multicastGroup),
            port: NWEndpoint.Port(rawValue: scanPort)!,
            using: .udp
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        connection.cancel()
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
                case .failed(let error):
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// Requests current status from a device. The response arrives at the
    /// persistent listener and triggers onDeviceStatusUpdate.
    func requestStatus(device: Device) async throws {
        try await sendCommand(to: device, cmd: "devStatus", data: [:])
    }

    // MARK: - Device Control

    func turnOn(device: Device) async throws {
        try await sendCommand(to: device, cmd: "turn", data: ["value": 1])
        logger.info("Turned ON: \(device.displayName)")
    }

    func turnOff(device: Device) async throws {
        try await sendCommand(to: device, cmd: "turn", data: ["value": 0])
        logger.info("Turned OFF: \(device.displayName)")
    }

    func setBrightness(device: Device, value: Int) async throws {
        let clamped = max(1, min(100, value))
        try await sendCommand(to: device, cmd: "brightness", data: ["value": clamped])
        logger.info("Brightness → \(clamped): \(device.displayName)")
    }

    func setColor(device: Device, r: Int, g: Int, b: Int) async throws {
        try await sendCommand(to: device, cmd: "colorwc", data: [
            "color": ["r": r, "g": g, "b": b],
            "colorTemInKelvin": 0
        ])
        logger.info("Color → (\(r),\(g),\(b)): \(device.displayName)")
    }

    func setColorTemperature(device: Device, kelvin: Int) async throws {
        let clamped = max(2000, min(9000, kelvin))
        try await sendCommand(to: device, cmd: "colorwc", data: [
            "color": ["r": 0, "g": 0, "b": 0],
            "colorTemInKelvin": clamped
        ])
        logger.info("Color temp → \(clamped)K: \(device.displayName)")
    }

    // MARK: - UDP Transport

    /// Maximum number of retry attempts for UDP commands.
    private let maxRetries = 2

    private func sendCommand(
        to device: Device,
        cmd: String,
        data: [String: Any]
    ) async throws {
        let message: [String: Any] = [
            "msg": [
                "cmd": cmd,
                "data": data
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)

        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                try await sendUDPPacket(jsonData, to: device)
                return
            } catch {
                lastError = error
                logger.warning("UDP send attempt \(attempt + 1)/\(self.maxRetries + 1) failed: \(error.localizedDescription)")
                if attempt < maxRetries {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        throw lastError!
    }

    private func sendUDPPacket(_ data: Data, to device: Device) async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(device.ip),
            port: NWEndpoint.Port(rawValue: commandPort)!,
            using: .udp
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        connection.cancel()
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
                case .failed(let error):
                    connection.cancel()
                    continuation.resume(throwing: error)
                case .waiting(let error):
                    // Connection can't be established (e.g. resource exhaustion)
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }
}
