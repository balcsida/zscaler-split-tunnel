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
    private(set) var lastDiscoveredDevice: DiscoveredDevice?
    private(set) var lastDiscoveryTime: Date?

    private var captures: [PacketCapture] = []
    private var config = Config()
    private let lock = NSLock()

    // MARK: - Configuration

    func updateConfig(_ config: Config) {
        lock.lock()
        self.config = config
        lock.unlock()

        if !config.enabled {
            stop()
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

        stopCaptures()

        let wifiIface = WiFiDetector.wifiInterfaceName()
        wifiInterface = wifiIface

        let interfaces = PacketCapture.listEthernetInterfaces()
            .filter { $0 != wifiIface } // Don't capture on WiFi

        guard !interfaces.isEmpty else {
            Self.logger.info("No Ethernet interfaces found for CDP/LLDP capture")
            mode = .notOffice
            return
        }

        mode = .detecting

        for iface in interfaces {
            let capture = PacketCapture(interfaceName: iface)
            capture.onDeviceDiscovered = { [weak self] device in
                self?.handleDiscovery(device)
            }
            capture.onError = { error in
                Self.logger.warning("Capture error: \(error)")
            }
            capture.start()
            captures.append(capture)
            Self.logger.info("Started CDP/LLDP capture on \(iface)")
        }
    }

    func stop() {
        stopCaptures()
        wifiGateway = nil
        lastDiscoveredDevice = nil
        lastDiscoveryTime = nil
    }

    private func stopCaptures() {
        for capture in captures {
            capture.stop()
        }
        captures.removeAll()
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
            mode = captures.isEmpty ? .notOffice : .detecting
        }

        return mode
    }

    // MARK: - Private

    private func handleDiscovery(_ device: DiscoveredDevice) {
        lock.lock()
        let patterns = config.switchNamePatterns
        lock.unlock()

        let name = device.systemName ?? device.deviceId ?? ""

        if !patterns.isEmpty {
            let matches = patterns.contains { pattern in
                matchesGlob(name: name.lowercased(), pattern: pattern.lowercased())
            }
            guard matches else {
                Self.logger.debug("Discovered device '\(name)' does not match switch patterns, ignoring")
                return
            }
        }

        Self.logger.info("Office switch detected: \(name) via \(device.protocolType.rawValue) on \(device.sourceInterface)")
        lastDiscoveredDevice = device
        lastDiscoveryTime = Date()
    }

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
