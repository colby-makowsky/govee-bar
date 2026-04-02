import Foundation
import os.log

/// Controls Govee devices via the cloud REST API.
/// Used as a fallback when LAN control fails.
actor GoveeCloudController {
    struct DeviceResponse: Codable {
        let code: Int
        let message: String
        let data: [CloudDevice]?
    }

    struct CloudDevice: Codable, Sendable {
        let sku: String
        let device: String
        let deviceName: String
        let capabilities: [Capability]?

        struct Capability: Codable, Sendable {
            let type: String
            let instance: String
        }
    }

    private let baseURL = "https://openapi.api.govee.com/router/api/v1"
    private let logger = Logger(subsystem: "com.govee-bar", category: "cloud")

    private var apiKey: String?

    func setAPIKey(_ key: String?) {
        apiKey = key
    }

    // MARK: - Device Discovery

    func getDevices() async throws -> [CloudDevice] {
        guard let apiKey, !apiKey.isEmpty else {
            throw CloudError.noAPIKey
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/user/devices")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(DeviceResponse.self, from: data)
            return decoded.data ?? []
        case 401:
            throw CloudError.unauthorized
        case 429:
            throw CloudError.rateLimited
        default:
            throw CloudError.httpError(httpResponse.statusCode)
        }
    }

    // MARK: - Device Control

    func turnOn(sku: String, device: String) async throws {
        try await sendControl(sku: sku, device: device, capability: [
            "type": "devices.capabilities.on_off",
            "instance": "powerSwitch",
            "value": 1,
        ])
    }

    func turnOff(sku: String, device: String) async throws {
        try await sendControl(sku: sku, device: device, capability: [
            "type": "devices.capabilities.on_off",
            "instance": "powerSwitch",
            "value": 0,
        ])
    }

    func setBrightness(sku: String, device: String, value: Int) async throws {
        let clamped = max(1, min(100, value))
        try await sendControl(sku: sku, device: device, capability: [
            "type": "devices.capabilities.range",
            "instance": "brightness",
            "value": clamped,
        ])
    }

    func setColor(sku: String, device: String, r: Int, g: Int, b: Int) async throws {
        let rgb = (r << 16) | (g << 8) | b
        try await sendControl(sku: sku, device: device, capability: [
            "type": "devices.capabilities.color_setting",
            "instance": "colorRgb",
            "value": rgb,
        ])
    }

    // MARK: - Transport

    private func sendControl(sku: String, device: String, capability: [String: Any]) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw CloudError.noAPIKey
        }

        let body: [String: Any] = [
            "requestId": UUID().uuidString,
            "payload": [
                "sku": sku,
                "device": device,
                "capability": capability,
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "\(baseURL)/device/control")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            logger.info("Cloud command sent successfully")
        case 401:
            throw CloudError.unauthorized
        case 429:
            throw CloudError.rateLimited
        default:
            throw CloudError.httpError(httpResponse.statusCode)
        }
    }

    // MARK: - Errors

    enum CloudError: LocalizedError {
        case noAPIKey
        case unauthorized
        case rateLimited
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No Govee API key configured"
            case .unauthorized: return "Invalid API key"
            case .rateLimited: return "API rate limit exceeded (10,000/day)"
            case .invalidResponse: return "Invalid response from Govee API"
            case .httpError(let code): return "HTTP error: \(code)"
            }
        }
    }
}
