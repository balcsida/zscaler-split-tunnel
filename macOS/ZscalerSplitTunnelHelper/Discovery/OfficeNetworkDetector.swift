import Foundation
import os

final class OfficeNetworkDetector: @unchecked Sendable {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "OfficeNetworkDetector")

    struct Config: Codable, Sendable {
        var enabled: Bool = false
        var targetSSID: String = "Guest_WiFi"
        var cdpGracePeriodSeconds: Int = 120
        var switchNamePatterns: [String] = []
    }

    private(set) var mode: OfficeMode = .disabled
    private(set) var wifiGateway: String?
    private(set) var wifiInterface: String?
    private(set) var lastDiscoveryTime: Date?

    private var config = Config()
    private let lock = NSLock()

    // MARK: - Configuration

    func updateConfig(_ config: Config) {
        lock.lock()
        self.config = config
        lock.unlock()

        if !config.enabled {
            mode = .disabled
        }
    }

    func loadConfig(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            Self.logger.info("No office mode config found or invalid, feature disabled")
            return
        }
        updateConfig(config)
        Self.logger.info("Loaded office mode config: enabled=\(config.enabled), SSID=\(config.targetSSID)")
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        let enabled = config.enabled
        lock.unlock()

        guard enabled else {
            mode = .disabled
            return
        }

        wifiInterface = WiFiDetector.wifiInterfaceName()
        mode = .detecting
    }

    func stop() {
        wifiGateway = nil
        lastDiscoveryTime = nil
    }

    /// Called by MonitorLoop when a CDP/LLDP device is discovered.
    func handleDiscovery(_ device: DiscoveredDevice) {
        lock.lock()
        let patterns = config.switchNamePatterns
        let enabled = config.enabled
        lock.unlock()

        guard enabled else { return }

        let name = device.systemName ?? device.deviceId ?? ""

        if !patterns.isEmpty {
            let matches = patterns.contains { pattern in
                matchesGlob(name: name.lowercased(), pattern: pattern.lowercased())
            }
            guard matches else {
                Self.logger.debug("Discovered device '\(name)' does not match switch patterns, ignoring for office mode")
                return
            }
        }

        Self.logger.info("Office switch detected: \(name) via \(device.protocolType.rawValue) on \(device.sourceInterface)")
        lastDiscoveryTime = Date()
    }

    // MARK: - Evaluation

    /// Called each monitor cycle to evaluate the current office mode.
    func evaluate() -> OfficeMode {
        lock.lock()
        let cfg = config
        lock.unlock()

        guard cfg.enabled else {
            mode = .disabled
            return mode
        }

        let isOffice = isInOffice(gracePeriod: cfg.cdpGracePeriodSeconds)

        if isOffice {
            // Check WiFi
            if let wifiIface = wifiInterface,
               let ssid = WiFiDetector.currentSSID(interface: wifiIface),
               ssid == cfg.targetSSID,
               let gateway = WiFiDetector.gateway(forInterface: wifiIface) {
                wifiGateway = gateway
                mode = .officeWifi
            } else {
                wifiGateway = nil
                mode = .officeNoWifi
            }
        } else if lastDiscoveryTime != nil {
            // Had a discovery before but grace period expired
            wifiGateway = nil
            mode = .notOffice
        } else {
            // Still detecting, no discovery yet
            mode = .detecting
        }

        return mode
    }

    // MARK: - Private

    private func isInOffice(gracePeriod: Int) -> Bool {
        guard let lastTime = lastDiscoveryTime else { return false }
        return Date().timeIntervalSince(lastTime) < TimeInterval(gracePeriod)
    }

    private func matchesGlob(name: String, pattern: String) -> Bool {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return name.hasPrefix(prefix)
        }
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return name.hasSuffix(suffix)
        }
        return name == pattern
    }
}
