import Foundation
import Network
import os.log

/// Controls Govee devices over the local network using UDP.
///
/// Discovery uses multicast (239.255.255.250:4001), devices respond on port 4002.
/// Commands are sent via unicast UDP to the device IP on port 4003.
actor GoveeLANController {
    struct Device: Identifiable, Codable, Sendable {
        let id: String        // MAC-based device ID
        let ip: String
        let sku: String
        let deviceName: String?

        var displayName: String {
            deviceName ?? "\(sku) (\(id))"
        }
    }

    private let logger = Logger(subsystem: "com.govee-bar", category: "lan")

    private let multicastGroup = "239.255.255.250"
    private let scanPort: UInt16 = 4001
    private let responsePort: UInt16 = 4002
    private let commandPort: UInt16 = 4003

    private var discoveredDevices: [String: Device] = [:]
    private var discoveryListener: NWListener?

    // MARK: - Discovery

    /// Discovers Govee devices on the local network.
    /// Sends a multicast scan and listens for responses for the given duration.
    func discoverDevices(timeout: TimeInterval = 3.0) async throws -> [Device] {
        discoveredDevices.removeAll()

        // Start listening for responses on port 4002
        let listener = try startResponseListener()
        self.discoveryListener = listener

        // Send scan command via multicast
        try await sendScanCommand()

        // Wait for responses
        try await Task.sleep(for: .seconds(timeout))

        // Clean up
        listener.cancel()
        self.discoveryListener = nil

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

        return try await withCheckedThrowingContinuation { continuation in
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

    private func startResponseListener() throws -> NWListener {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: responsePort)!)

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receiveResponse(on: connection)
        }

        listener.start(queue: .global())
        return listener
    }

    private nonisolated func receiveResponse(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, let content, error == nil else {
                connection.cancel()
                return
            }

            Task {
                await self.handleDiscoveryResponse(data: content, connection: connection)
            }
        }
    }

    private func handleDiscoveryResponse(data: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["msg"] as? [String: Any],
              let cmd = msg["cmd"] as? String, cmd == "scan",
              let responseData = msg["data"] as? [String: Any] else {
            connection.cancel()
            return
        }

        let ip = responseData["ip"] as? String ?? ""
        let device = responseData["device"] as? String ?? ""
        let sku = responseData["sku"] as? String ?? ""
        let deviceName = responseData["deviceName"] as? String

        guard !device.isEmpty, !ip.isEmpty else {
            connection.cancel()
            return
        }

        let goveeDevice = Device(id: device, ip: ip, sku: sku, deviceName: deviceName)
        discoveredDevices[device] = goveeDevice
        logger.info("Discovered device: \(sku) at \(ip)")

        connection.cancel()
    }

    // MARK: - Device Control

    func turnOn(device: Device) async throws {
        _ = try await sendCommand(to: device, cmd: "turn", data: ["value": 1])
        logger.info("Turned ON: \(device.displayName)")
    }

    func turnOff(device: Device) async throws {
        _ = try await sendCommand(to: device, cmd: "turn", data: ["value": 0])
        logger.info("Turned OFF: \(device.displayName)")
    }

    func setBrightness(device: Device, value: Int) async throws {
        let clamped = max(1, min(100, value))
        _ = try await sendCommand(to: device, cmd: "brightness", data: ["value": clamped])
        logger.info("Brightness → \(clamped): \(device.displayName)")
    }

    func setColor(device: Device, r: Int, g: Int, b: Int) async throws {
        _ = try await sendCommand(to: device, cmd: "colorwc", data: [
            "color": ["r": r, "g": g, "b": b],
            "colorTemInKelvin": 0
        ])
        logger.info("Color → (\(r),\(g),\(b)): \(device.displayName)")
    }

    func setColorTemperature(device: Device, kelvin: Int) async throws {
        let clamped = max(2000, min(9000, kelvin))
        _ = try await sendCommand(to: device, cmd: "colorwc", data: [
            "color": ["r": 0, "g": 0, "b": 0],
            "colorTemInKelvin": clamped
        ])
        logger.info("Color temp → \(clamped)K: \(device.displayName)")
    }

    func getStatus(device: Device) async throws -> [String: Any]? {
        try await sendCommand(to: device, cmd: "devStatus", data: [:], expectResponse: true)
    }

    // MARK: - UDP Transport

    private func sendCommand(
        to device: Device,
        cmd: String,
        data: [String: Any],
        expectResponse: Bool = false
    ) async throws -> [String: Any]? {
        let message: [String: Any] = [
            "msg": [
                "cmd": cmd,
                "data": data
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)

        let connection = NWConnection(
            host: NWEndpoint.Host(device.ip),
            port: NWEndpoint.Port(rawValue: commandPort)!,
            using: .udp
        )

        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: jsonData, completion: .contentProcessed { error in
                        if let error {
                            connection.cancel()
                            continuation.resume(throwing: error)
                            return
                        }

                        if expectResponse {
                            connection.receiveMessage { content, _, _, error in
                                defer { connection.cancel() }
                                if let error {
                                    continuation.resume(throwing: error)
                                } else if let content,
                                          let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any] {
                                    continuation.resume(returning: json)
                                } else {
                                    continuation.resume(returning: nil)
                                }
                            }
                        } else {
                            connection.cancel()
                            continuation.resume(returning: nil)
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
}
