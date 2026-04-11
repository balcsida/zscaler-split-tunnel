import Foundation
import os

final class MonitorLoop: @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.helperBundleID, category: "MonitorLoop")
    private let configLoader: ConfigLoader

    let officeDetector = OfficeNetworkDetector()

    init() {
        self.configLoader = ConfigLoader(
            dnsResolver: DNSResolver(cacheURL: ConfigPaths.consoleUserDomainCache),
            remoteFetcher: RemoteRouteFetcher(cacheURL: ConfigPaths.consoleUserRemoteRouteCache)
        )
    }

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.zscaler-split-tunnel.helper.monitor", qos: .utility)
    private(set) var isRunning = false
    private(set) var interval: Int = AppConstants.defaultMonitorInterval
    private var lastNetworkSignature: String?
    private var lastConfigSignature: String?
    private var lastBypassGateway: String?

    private(set) var customRouteCount: Int = 0
    private(set) var bypassRouteCount: Int = 0
    private(set) var lastRefresh: Date?
    private(set) var officeMode: OfficeMode = .disabled
    private(set) var lastDiscoveredDevice: DiscoveredDevice?
    private var captures: [PacketCapture] = []
    private(set) var captureErrors: [String] = []
    private(set) var activeCapureInterfaces: [String] = []
    private(set) var allEthernetInterfaces: [String] = []
    private(set) var wifiInterface: String?
    /// The name of the last device that matched office switch patterns (set by OfficeNetworkDetector).
    private(set) var officeSwitchName: String?

    /// A point-in-time snapshot of MonitorLoop state, safe to read from any thread.
    struct StatusSnapshot {
        let lastDiscoveredDevice: DiscoveredDevice?
        let activeCaptureInterfaces: [String]
        let allEthernetInterfaces: [String]
        let wifiInterface: String?
        let captureErrors: [String]
        let customRouteCount: Int
        let bypassRouteCount: Int
        let lastRefresh: Date?
        let officeMode: OfficeMode
        let officeSwitchName: String?
        let officeWifiGateway: String?
        let isRunning: Bool
        let interval: Int
    }

    /// Returns a consistent snapshot of all status properties, read under the monitor queue.
    func statusSnapshot(completion: @escaping (StatusSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(StatusSnapshot(
                    lastDiscoveredDevice: nil, activeCaptureInterfaces: [],
                    allEthernetInterfaces: [], wifiInterface: nil, captureErrors: [],
                    customRouteCount: 0, bypassRouteCount: 0, lastRefresh: nil,
                    officeMode: .disabled, officeSwitchName: nil, officeWifiGateway: nil,
                    isRunning: false, interval: 0
                ))
                return
            }
            completion(StatusSnapshot(
                lastDiscoveredDevice: self.lastDiscoveredDevice,
                activeCaptureInterfaces: self.activeCapureInterfaces,
                allEthernetInterfaces: self.allEthernetInterfaces,
                wifiInterface: self.wifiInterface,
                captureErrors: self.captureErrors,
                customRouteCount: self.customRouteCount,
                bypassRouteCount: self.bypassRouteCount,
                lastRefresh: self.lastRefresh,
                officeMode: self.officeMode,
                officeSwitchName: self.officeSwitchName,
                officeWifiGateway: self.officeDetector.wifiGateway,
                isRunning: self.isRunning,
                interval: self.interval
            ))
        }
    }

    func start(interval: Int) {
        guard !isRunning else {
            logger.info("Monitor already running")
            return
        }
        self.interval = interval
        isRunning = true
        logger.info("Starting route monitoring (interval: \(interval)s)")

        // Run all state-mutating work on the monitor queue to avoid data races
        queue.async { [weak self] in
            guard let self else { return }
            self.lastNetworkSignature = NetworkDetector.getNetworkSignature()
            self.officeDetector.loadConfig(from: ConfigPaths.consoleUserOfficeModeConfig)
            self.officeDetector.start()
            self.startCaptures()
            self.runCycle()
        }

        // Schedule timer on background queue to avoid blocking XPC on the main RunLoop
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.runCycle()
        }
        t.resume()
        timer = t
    }

    func stop() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.stopCaptures()
            self.officeDetector.stop()
            self.lastDiscoveredDevice = nil
            self.officeSwitchName = nil
        }
        logger.info("Stopped route monitoring")
    }

    func refresh() {
        logger.info("Manual refresh triggered")
        queue.async { [weak self] in
            self?.handleNetworkChange()
        }
    }

    // MARK: - Private

    private func runCycle() {
        guard isRunning else { return }

        // Evaluate office mode
        officeMode = officeDetector.evaluate()

        // Check for network changes
        let currentSignature = NetworkDetector.getNetworkSignature()
        if let last = lastNetworkSignature, currentSignature != last {
            logger.info("Network changed from '\(last)' to '\(currentSignature)'")
            lastNetworkSignature = currentSignature
            handleNetworkChange()
            return
        }
        lastNetworkSignature = currentSignature

        // Check for new/removed Ethernet interfaces (e.g. dock connected/disconnected)
        let currentInterfaces = Set(PacketCapture.listEthernetInterfaces())
        if currentInterfaces != Set(allEthernetInterfaces) {
            let removed = Set(allEthernetInterfaces).subtracting(currentInterfaces)
            logger.info("Ethernet interfaces changed (\(self.allEthernetInterfaces) -> \(Array(currentInterfaces))), restarting captures")

            // Clear cached device if its source interface was disconnected
            if let deviceIface = lastDiscoveredDevice?.sourceInterface, removed.contains(deviceIface) {
                logger.info("Clearing cached device (interface \(deviceIface) disconnected)")
                lastDiscoveredDevice = nil
            }

            stopCaptures()
            startCaptures()
        }

        // Check for config changes
        if configHasChanged() {
            logger.info("Configuration file changed, reloading...")
            configLoader.clearCaches()
            officeDetector.loadConfig(from: ConfigPaths.consoleUserOfficeModeConfig)
            officeMode = officeDetector.evaluate()
            reloadAndApplyRoutes()
        } else {
            // Check if bypass gateway changed (office mode transition)
            let currentBypassGateway = resolveBypassGateway()
            if currentBypassGateway != lastBypassGateway, lastBypassGateway != nil {
                logger.info("Bypass gateway changed (\(self.lastBypassGateway ?? "nil") -> \(currentBypassGateway ?? "nil")), refreshing bypass routes")
                reloadAndApplyRoutes()
            } else {
                _ = BroadRouteManager.removeBroadRoutes()
                addCustomRoutes()
                addBypassRoutes()
            }
        }

        lastRefresh = Date()
    }

    private func handleNetworkChange() {
        logger.info("Network change detected! Refreshing all routes...")
        DNSFlush.flush()
        configLoader.clearCaches()
        lastConfigSignature = nil
        lastBypassGateway = nil

        // Restart captures and office detection on new network
        stopCaptures()
        officeDetector.stop()
        officeDetector.start()

        // Only clear cached device if its source interface is no longer present
        if let deviceIface = lastDiscoveredDevice?.sourceInterface,
           !PacketCapture.listEthernetInterfaces().contains(deviceIface) {
            logger.info("Clearing cached device (interface \(deviceIface) no longer present)")
            lastDiscoveredDevice = nil
            officeSwitchName = nil
        }

        startCaptures()
        officeMode = officeDetector.evaluate()

        reloadAndApplyRoutes()
        lastRefresh = Date()
    }

    // MARK: - CDP/LLDP Capture

    private func startCaptures() {
        stopCaptures()

        let wifiIface = WiFiDetector.wifiInterfaceName()
        wifiInterface = wifiIface
        let allInterfaces = PacketCapture.listEthernetInterfaces()
        allEthernetInterfaces = allInterfaces
        captureErrors = []
        let interfaces = allInterfaces.filter { $0 != wifiIface }

        guard !interfaces.isEmpty else {
            logger.info("No Ethernet interfaces found for CDP/LLDP capture (all en*: \(allInterfaces), wifi: \(wifiIface ?? "none"))")
            return
        }
        var started: [String] = []

        for iface in interfaces {
            let capture = PacketCapture(interfaceName: iface)
            capture.onDeviceDiscovered = { [weak self] device in
                self?.queue.async { [weak self] in
                    self?.handleDiscovery(device)
                }
            }
            capture.onError = { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.logger.warning("Capture error on \(iface): \(error)")
                    self.captureErrors.append("\(iface): \(error)")
                }
            }
            capture.start()
            captures.append(capture)
            started.append(iface)
            logger.info("Started CDP/LLDP capture on \(iface)")
        }

        activeCapureInterfaces = started
    }

    private func stopCaptures() {
        for capture in captures {
            capture.stop()
        }
        captures.removeAll()
        activeCapureInterfaces = []
    }

    private func handleDiscovery(_ device: DiscoveredDevice) {
        let name = device.displayTitle
        logger.info("Discovered device: \(name) via \(device.protocolType.rawValue) on \(device.sourceInterface)")

        // Merge into existing data if same interface, otherwise replace
        if var existing = lastDiscoveredDevice, existing.sourceInterface == device.sourceInterface {
            existing.merge(from: device)
            lastDiscoveredDevice = existing
        } else {
            lastDiscoveredDevice = device
        }

        // Update office switch name only if the device matched office patterns
        let previousDiscoveryTime = officeDetector.lastDiscoveryTime
        officeDetector.handleDiscovery(device)
        if officeDetector.lastDiscoveryTime != previousDiscoveryTime {
            officeSwitchName = device.systemName ?? device.deviceId
        }
    }

    // MARK: - Routes

    private func reloadAndApplyRoutes() {
        _ = BroadRouteManager.removeBroadRoutes()

        let customRoutes = configLoader.loadRoutes(
            defaultFile: ConfigPaths.defaultRoutesConfig,
            userFile: ConfigPaths.consoleUserRoutesConfig
        )
        let bypassRoutes = configLoader.loadBypassRoutes(
            defaultFile: ConfigPaths.defaultBypassConfig,
            userFile: ConfigPaths.consoleUserBypassConfig
        )

        customRouteCount = customRoutes.count
        bypassRouteCount = bypassRoutes.count

        addRoutes(customRoutes, bypass: false)
        addRoutes(bypassRoutes, bypass: true)
    }

    private func addCustomRoutes() {
        let routes = configLoader.loadRoutes(
            defaultFile: ConfigPaths.defaultRoutesConfig,
            userFile: ConfigPaths.consoleUserRoutesConfig
        )
        customRouteCount = routes.count
        addRoutes(routes, bypass: false)
    }

    private func addBypassRoutes() {
        let routes = configLoader.loadBypassRoutes(
            defaultFile: ConfigPaths.defaultBypassConfig,
            userFile: ConfigPaths.consoleUserBypassConfig
        )
        bypassRouteCount = routes.count
        addRoutes(routes, bypass: true)
    }

    /// Resolves the gateway to use for bypass routes, considering office mode.
    private func resolveBypassGateway() -> String? {
        if officeMode == .officeWifi, let wifiGW = officeDetector.wifiGateway {
            return wifiGW
        }
        return RouteEngine.getDefaultGateway()
    }

    private func addRoutes(_ routes: [String], bypass: Bool) {
        if bypass {
            let gateway = resolveBypassGateway()
            guard let gateway else {
                logger.error("Cannot add bypass routes: no gateway available")
                return
            }

            if officeMode == .officeWifi {
                logger.info("Routing \(routes.count) bypass routes via WiFi gateway \(gateway)")
            }

            lastBypassGateway = gateway

            for route in routes {
                let isIPv6 = IPValidator.isIPv6(route)
                if !RouteEngine.routeExists(destination: route, isIPv6: isIPv6) {
                    _ = RouteEngine.addBypassRoute(destination: route, gateway: gateway, isIPv6: isIPv6)
                }
            }
        } else {
            guard let iface = RouteEngine.detectZscalerInterface() else {
                logger.error("Cannot add custom routes: Zscaler interface not detected")
                return
            }
            for route in routes {
                let isIPv6 = IPValidator.isIPv6(route)
                if !RouteEngine.routeExists(destination: route, isIPv6: isIPv6) {
                    _ = RouteEngine.addRoute(destination: route, interface: iface, isIPv6: isIPv6)
                }
            }
        }
    }

    private func configHasChanged() -> Bool {
        var trackedFiles = [
            ConfigPaths.consoleUserRoutesConfig,
            ConfigPaths.consoleUserBypassConfig,
            ConfigPaths.consoleUserOfficeModeConfig,
        ]
        if let legacyRoutes = ConfigPaths.consoleUserLegacyRoutesConfig {
            trackedFiles.append(legacyRoutes)
        }
        if let legacyBypass = ConfigPaths.consoleUserLegacyBypassConfig {
            trackedFiles.append(legacyBypass)
        }

        var signature = ""
        let fm = FileManager.default
        for file in trackedFiles {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let mtime = attrs[.modificationDate] as? Date {
                signature += "\(file.path):\(mtime.timeIntervalSince1970);"
            } else {
                signature += "\(file.path):missing;"
            }
        }

        defer { lastConfigSignature = signature }

        if let last = lastConfigSignature {
            return signature != last
        }
        return false
    }
}
