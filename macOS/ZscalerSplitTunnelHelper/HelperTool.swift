import Foundation
import os

final class HelperTool: NSObject, NSXPCListenerDelegate, HelperToolProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.helperBundleID, category: "HelperTool")
    private let monitorLoop = MonitorLoop()

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = { [weak self] in
            self?.logger.info("XPC connection invalidated")
        }

        newConnection.resume()
        logger.info("Accepted new XPC connection (pid: \(newConnection.processIdentifier))")
        return true
    }

    // MARK: - HelperToolProtocol

    func removeBroadRoutes(reply: @escaping (Int, String?) -> Void) {
        let count = BroadRouteManager.removeBroadRoutes()
        reply(count, nil)
    }

    func addRoute(_ route: String, viaInterface: String, isIPv6: Bool,
                  reply: @escaping (Bool, String?) -> Void) {
        let success = RouteEngine.addRoute(destination: route, interface: viaInterface, isIPv6: isIPv6)
        reply(success, success ? nil : "Failed to add route \(route)")
    }

    func addBypassRoute(_ route: String, gateway: String, isIPv6: Bool,
                        reply: @escaping (Bool, String?) -> Void) {
        let success = RouteEngine.addBypassRoute(destination: route, gateway: gateway, isIPv6: isIPv6)
        reply(success, success ? nil : "Failed to add direct override \(route)")
    }

    func deleteRoute(_ route: String, isIPv6: Bool,
                     reply: @escaping (Bool, String?) -> Void) {
        let success = RouteEngine.deleteRoute(destination: route, isIPv6: isIPv6)
        reply(success, success ? nil : "Failed to delete route \(route)")
    }

    func startMonitoring(intervalSeconds: Int, reply: @escaping (Bool, String?) -> Void) {
        let interval = intervalSeconds > 0 ? intervalSeconds : AppConstants.defaultMonitorInterval
        monitorLoop.start(interval: interval)
        reply(true, nil)
    }

    func stopMonitoring(reply: @escaping (Bool, String?) -> Void) {
        monitorLoop.stop()
        reply(true, nil)
    }

    func triggerRefresh(reply: @escaping (Bool, String?) -> Void) {
        monitorLoop.refresh()
        reply(true, nil)
    }

    func flushDNSCache(reply: @escaping (Bool, String?) -> Void) {
        DNSFlush.flush()
        reply(true, nil)
    }

    func startZscaler(consoleUser: String, reply: @escaping (Bool, String?) -> Void) {
        ZscalerServiceManager.start(consoleUser: consoleUser)
        reply(true, nil)
    }

    func killZscaler(consoleUser: String, reply: @escaping (Bool, String?) -> Void) {
        // Stop the monitor first so it can't re-install direct override /32s
        // or Zscaler routes between the pkill and the RouteReset. Then kill Zscaler, then
        // run RouteReset to clear the stale utun-scoped defaults, flush leftover
        // /32s pinned to the previous gateway, and bounce active en* services so
        // IPv4 default + DNS come back without Zscaler's 100.64.0.1 override.
        logger.info("killZscaler: stopping monitor → killing Zscaler → resetting routes")
        monitorLoop.stop()
        ZscalerServiceManager.kill(consoleUser: consoleUser)
        let result = RouteReset.run()
        let err = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
        reply(err == nil, err)
    }

    func getStatus(reply: @escaping (Data) -> Void) {
        let broadRoutes = BroadRouteManager.countPresentRoutes()
        let zscalerRunning = ZscalerServiceManager.isRunning()
        let zscalerInterface = RouteEngine.detectZscalerInterface()
        let networkSignature = NetworkDetector.getNetworkSignature()

        // Read all MonitorLoop state from a single synchronized snapshot
        monitorLoop.statusSnapshot { [weak self] snapshot in
            let status = HelperStatus(
                isMonitoring: snapshot.isRunning,
                monitorInterval: snapshot.interval,
                zscalerRunning: zscalerRunning,
                zscalerInterface: zscalerInterface,
                broadRoutesPresent: HelperStatus.BroadRouteStatus(
                    ipv4Present: broadRoutes.ipv4,
                    ipv4Total: AppConstants.ipv4BroadRoutes.count,
                    ipv6Present: broadRoutes.ipv6,
                    ipv6Total: AppConstants.ipv6BroadRoutes.count
                ),
                customRouteCount: snapshot.customRouteCount,
                bypassRouteCount: snapshot.bypassRouteCount,
                lastRefresh: snapshot.lastRefresh,
                networkSignature: networkSignature,
                version: BuildInfo.gitCommitSHA,
                officeMode: snapshot.officeMode,
                officeSwitchName: snapshot.officeSwitchName,
                officeWifiGateway: snapshot.officeWifiGateway,
                discoveredDevice: snapshot.lastDiscoveredDevice?.toInfo(),
                captureStatus: HelperStatus.CaptureStatus(
                    activeInterfaces: snapshot.activeCaptureInterfaces,
                    allEthernetInterfaces: snapshot.allEthernetInterfaces,
                    wifiInterface: snapshot.wifiInterface,
                    errors: snapshot.captureErrors
                ),
                staleRouteCleanup: snapshot.staleRouteCleanup
            )

            do {
                let data = try JSONEncoder().encode(status)
                reply(data)
            } catch {
                self?.logger.error("Failed to encode status: \(error.localizedDescription)")
                reply(Data())
            }
        }
    }

    func enableAutostart(reply: @escaping (Bool, String?) -> Void) {
        // The helper is managed via SMJobBless - autostart is handled by the launchd plist
        logger.info("Autostart is managed by the LaunchDaemon plist")
        reply(true, nil)
    }

    func disableAutostart(reply: @escaping (Bool, String?) -> Void) {
        logger.info("Autostart is managed by the LaunchDaemon plist")
        reply(true, nil)
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(BuildInfo.gitCommitSHA)
    }

    func resetRoutes(reply: @escaping ([String], String?) -> Void) {
        let result = RouteReset.run()
        let err = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
        reply(result.bouncedServices, err)
    }
}
