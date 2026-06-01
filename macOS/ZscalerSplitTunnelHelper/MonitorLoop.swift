import Foundation
import os

final class MonitorLoop: @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.helperBundleID, category: "MonitorLoop")
    private let configLoader: ConfigLoader
    private let networkMonitor = NetworkChangeMonitor()

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
    private var lastDefaultRouteRepairAttempt: Date?
    private var lastIPv6DefaultRouteRepairAttempt: Date?

    private static let followUpCount: Int = 4
    private static let followUpInterval: TimeInterval = 6
    private static let defaultRouteRepairCooldown: TimeInterval = 30
    private var pendingFollowUpSweeps: Int = 0

    private(set) var customRouteCount: Int = 0
    private(set) var bypassRouteCount: Int = 0
    private(set) var lastRefresh: Date?
    private(set) var officeMode: OfficeMode = .disabled
    private(set) var lastDiscoveredDevice: DiscoveredDevice?
    private var captures: [PacketCapture] = []
    private(set) var captureErrors: [String] = []
    private(set) var activeCaptureInterfaces: [String] = []
    private(set) var allEthernetInterfaces: [String] = []
    private(set) var wifiInterface: String?
    /// The name of the last device that matched office switch patterns (set by OfficeNetworkDetector).
    private(set) var officeSwitchName: String?

    // Lock-protected snapshot so statusSnapshot() never has to wait for the monitor queue.
    private let snapshotLock = NSLock()
    private var _cachedSnapshot: StatusSnapshot?

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

    /// Returns a consistent snapshot of all status properties.
    ///
    /// Reads from a lock-protected cache that is refreshed at the end of every
    /// monitor-queue cycle, so this call never blocks waiting for the monitor
    /// queue to become free (which would cause a `getStatus` XPC timeout while
    /// a long-running `handleNetworkChange` is in progress).
    func statusSnapshot(completion: @escaping (StatusSnapshot) -> Void) {
        snapshotLock.lock()
        let snapshot = _cachedSnapshot
        snapshotLock.unlock()

        completion(snapshot ?? StatusSnapshot(
            lastDiscoveredDevice: nil, activeCaptureInterfaces: [],
            allEthernetInterfaces: [], wifiInterface: nil, captureErrors: [],
            customRouteCount: 0, bypassRouteCount: 0, lastRefresh: nil,
            officeMode: .disabled, officeSwitchName: nil, officeWifiGateway: nil,
            isRunning: false, interval: 0
        ))
    }

    /// Must be called on `queue`. Captures current state into the lock-protected cache.
    private func updateSnapshot() {
        let snapshot = StatusSnapshot(
            lastDiscoveredDevice: lastDiscoveredDevice,
            activeCaptureInterfaces: activeCaptureInterfaces,
            allEthernetInterfaces: allEthernetInterfaces,
            wifiInterface: wifiInterface,
            captureErrors: captureErrors,
            customRouteCount: customRouteCount,
            bypassRouteCount: bypassRouteCount,
            lastRefresh: lastRefresh,
            officeMode: officeMode,
            officeSwitchName: officeSwitchName,
            officeWifiGateway: officeDetector.wifiGateway,
            isRunning: isRunning,
            interval: interval
        )
        snapshotLock.lock()
        _cachedSnapshot = snapshot
        snapshotLock.unlock()
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
            self.lastDefaultRouteRepairAttempt = nil
            self.lastIPv6DefaultRouteRepairAttempt = nil
            self.pendingFollowUpSweeps = 0
            self.lastNetworkSignature = NetworkDetector.getNetworkSignature()
            self.officeDetector.loadConfig(from: ConfigPaths.consoleUserOfficeModeConfig)
            self.officeDetector.start()
            self.startCaptures()
            self.runCycle()
        }

        // Event-driven network change detection via SCDynamicStore. The polling
        // timer below is retained as a safety net and still handles config
        // reloads, interface-list diffs, and broad-route sweeps, but the
        // primary "network changed" trigger is now event-driven.
        networkMonitor.start { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in self?.handleNetworkChangeEvent() }
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
        networkMonitor.stop()
        queue.sync { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.lastDefaultRouteRepairAttempt = nil
            self.lastIPv6DefaultRouteRepairAttempt = nil
            self.timer?.cancel()
            self.timer = nil
            self.pendingFollowUpSweeps = 0
            self.stopCaptures()
            self.officeDetector.stop()
            self.lastDiscoveredDevice = nil
            self.officeSwitchName = nil
            self.updateSnapshot()
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

        repairDefaultRouteIfNeeded()

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
                logger.info("Direct override gateway changed (\(self.lastBypassGateway ?? "nil") -> \(currentBypassGateway ?? "nil")), refreshing direct overrides")
                reloadAndApplyRoutes()
            } else {
                sweepBroadRoutesAndRepairIPv6Default()
                addCustomRoutes()
                addBypassRoutes()
            }
        }

        lastRefresh = Date()
        updateSnapshot()
    }

    /// Entry point for SCDynamicStore-driven change notifications. Runs on
    /// `queue`. Re-checks the network signature so duplicate events coalesced
    /// after the debounce window (e.g. v4-then-v6 updates that land within the
    /// same transition) still produce exactly one `handleNetworkChange` pass.
    private func handleNetworkChangeEvent() {
        guard isRunning else { return }
        let currentSignature = NetworkDetector.getNetworkSignature()
        guard currentSignature != lastNetworkSignature else {
            logger.debug("SC event: signature unchanged (\(currentSignature, privacy: .public)), skipping")
            return
        }
        let previous = lastNetworkSignature ?? "(none)"
        logger.info("SC event: network changed from '\(previous, privacy: .public)' to '\(currentSignature, privacy: .public)'")
        lastNetworkSignature = currentSignature
        handleNetworkChange()
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

        // Flush any stale cloned host routes left over from the previous IP
        // address. After a DHCP change (e.g. coffee shop → home) the kernel
        // retains /32 and /128 WASCLONED entries that still carry the old
        // preferred source address, causing EADDRNOTAVAIL for new connections
        // to those destinations. We delete them here so they are re-cloned
        // with the correct source address when routes are reinstalled below.
        RouteEngine.flushStaleHostRoutes()
        repairDefaultRouteIfNeeded(force: true)

        reloadAndApplyRoutes(forceReplace: true)
        repairIPv6DefaultRouteIfNeeded(force: true)
        lastRefresh = Date()
        updateSnapshot()
        scheduleFollowUpSweeps()
    }

    /// After a network change, Zscaler reconnects asynchronously and may reinstall
    /// its broad routes *after* `handleNetworkChange` has already swept. Schedule
    /// a short series of follow-up broad-route sweeps to catch that race without
    /// waiting for the full monitor cycle.
    private func scheduleFollowUpSweeps() {
        pendingFollowUpSweeps = Self.followUpCount
        scheduleNextFollowUpSweep()
    }

    private func scheduleNextFollowUpSweep() {
        guard pendingFollowUpSweeps > 0 else { return }
        queue.asyncAfter(deadline: .now() + Self.followUpInterval) { [weak self] in
            guard let self, self.isRunning, self.pendingFollowUpSweeps > 0 else { return }
            self.pendingFollowUpSweeps -= 1
            let done = Self.followUpCount - self.pendingFollowUpSweeps
            self.logger.info("Follow-up broad-route sweep (\(done)/\(Self.followUpCount))")
            let removed = self.sweepBroadRoutesAndRepairIPv6Default()
            if removed > 0 {
                self.logger.info("Follow-up sweep removed \(removed) broad route(s)")
            }
            self.scheduleNextFollowUpSweep()
        }
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

        activeCaptureInterfaces = started
    }

    private func stopCaptures() {
        for capture in captures {
            capture.stop()
        }
        captures.removeAll()
        activeCaptureInterfaces = []
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

        updateSnapshot()
    }

    // MARK: - Routes

    private func repairDefaultRouteIfNeeded(force: Bool = false) {
        guard !DefaultRouteRepair.isUsableIPv4Gateway(RouteEngine.getDefaultGateway()) else {
            lastDefaultRouteRepairAttempt = nil
            return
        }

        let now = Date()
        if !force,
           let last = lastDefaultRouteRepairAttempt,
           now.timeIntervalSince(last) < Self.defaultRouteRepairCooldown {
            logger.debug("Skipping default-route repair attempt due to cooldown")
            return
        }
        lastDefaultRouteRepairAttempt = now

        let result = DefaultRouteRepair.restoreIfMissing()
        switch result {
        case .defaultPresent:
            logger.debug("Default route is already present")
        case .noActiveServices:
            logger.warning("Cannot repair missing IPv4 default route: no active network services")
        case .repairedByRouteChange(let service, let gateway):
            logger.info("Repaired missing IPv4 default route via route change using \(service, privacy: .public) gateway \(gateway, privacy: .public)")
        case .repairedByRouteAdd(let service, let gateway):
            logger.info("Repaired missing IPv4 default route via route add using \(service, privacy: .public) gateway \(gateway, privacy: .public)")
        case .repairedByDHCP(let service, let gateway):
            logger.info("Repaired missing IPv4 default route via DHCP renew on \(service, privacy: .public), gateway \(gateway, privacy: .public)")
        case .failed(let errors):
            logger.error("Failed to repair missing IPv4 default route: \(errors.joined(separator: "; "), privacy: .public)")
        }
    }

    private func repairIPv6DefaultRouteIfNeeded(force: Bool = false) {
        let now = Date()
        if !force,
           let last = lastIPv6DefaultRouteRepairAttempt,
           now.timeIntervalSince(last) < Self.defaultRouteRepairCooldown {
            logger.debug("Skipping IPv6 default-route repair attempt due to cooldown")
            return
        }

        let result = IPv6DefaultRouteRepair.restoreIfMissing()
        switch result {
        case .defaultPresent:
            lastIPv6DefaultRouteRepairAttempt = nil
            logger.debug("IPv6 default route is already present")
        case .noDefaultRouters:
            lastIPv6DefaultRouteRepairAttempt = now
            logger.warning("Cannot repair missing IPv6 default route: no non-tunnel NDP router available")
        case .repaired(let gateway, let interface):
            lastIPv6DefaultRouteRepairAttempt = nil
            logger.info("Repaired missing IPv6 default route via \(gateway, privacy: .public) on \(interface, privacy: .public)")
        case .failed(let errors):
            lastIPv6DefaultRouteRepairAttempt = now
            logger.error("Failed to repair missing IPv6 default route: \(errors.joined(separator: "; "), privacy: .public)")
        }
    }

    private func reloadAndApplyRoutes(forceReplace: Bool = false) {
        sweepBroadRoutesAndRepairIPv6Default()

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
        addRoutes(bypassRoutes, bypass: true, forceReplace: forceReplace)
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

    /// Resolves the gateway to use for direct overrides, considering office mode.
    private func resolveBypassGateway() -> String? {
        if officeMode == .officeWifi, let wifiGW = officeDetector.wifiGateway {
            return wifiGW
        }
        return RouteEngine.getDefaultGateway()
    }

    private func addRoutes(_ routes: [String], bypass: Bool, forceReplace: Bool = false) {
        if bypass {
            let gateway = resolveBypassGateway()
            guard let gateway else {
                logger.error("Cannot add direct overrides: no gateway available")
                return
            }

            if officeMode == .officeWifi {
                logger.info("Routing \(routes.count) direct overrides via WiFi gateway \(gateway)")
            }

            lastBypassGateway = gateway

            let gatewayIsIPv6 = IPValidator.isIPv6(gateway)

            for route in routes {
                let isIPv6 = IPValidator.isIPv6(route)
                // A route's address family must match the gateway's address family.
                // Skipping mismatched routes avoids macOS rejecting the `route add`
                // command (e.g. an IPv6 destination via an IPv4 gateway), which would
                // leave those routes unset and cause ERR_ADDRESS_INVALID in browsers
                // whose Happy Eyeballs logic prefers IPv6.
                guard isIPv6 == gatewayIsIPv6 else {
                    logger.debug("Skipping \(isIPv6 ? "IPv6" : "IPv4") direct override \(route, privacy: .public): gateway \(gateway, privacy: .public) is \(gatewayIsIPv6 ? "IPv6" : "IPv4")")
                    continue
                }
                _ = RouteEngine.ensureBypassRoute(
                    destination: route,
                    gateway: gateway,
                    isIPv6: isIPv6,
                    forceReplace: forceReplace
                )
            }
        } else {
            guard let iface = RouteEngine.detectZscalerInterface() else {
                logger.error("Cannot add Zscaler routes: Zscaler interface not detected")
                return
            }
            for route in routes {
                let isIPv6 = IPValidator.isIPv6(route)
                _ = RouteEngine.replaceRoute(destination: route, interface: iface, isIPv6: isIPv6)
            }
        }
    }

    @discardableResult
    private func sweepBroadRoutesAndRepairIPv6Default() -> Int {
        let removed = BroadRouteManager.removeBroadRoutes()
        repairIPv6DefaultRouteIfNeeded(force: removed > 0)
        return removed
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
