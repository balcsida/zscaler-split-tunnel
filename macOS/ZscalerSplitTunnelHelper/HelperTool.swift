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
        reply(success, success ? nil : "Failed to add bypass route \(route)")
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
        ZscalerServiceManager.kill(consoleUser: consoleUser)
        reply(true, nil)
    }

    func getStatus(reply: @escaping (Data) -> Void) {
        let broadRoutes = BroadRouteManager.countPresentRoutes()
        let zscalerRunning = ZscalerServiceManager.isRunning()
        let zscalerInterface = RouteEngine.detectZscalerInterface()

        let status = HelperStatus(
            isMonitoring: monitorLoop.isRunning,
            monitorInterval: monitorLoop.interval,
            zscalerRunning: zscalerRunning,
            zscalerInterface: zscalerInterface,
            broadRoutesPresent: HelperStatus.BroadRouteStatus(
                ipv4Present: broadRoutes.ipv4,
                ipv4Total: AppConstants.ipv4BroadRoutes.count,
                ipv6Present: broadRoutes.ipv6,
                ipv6Total: AppConstants.ipv6BroadRoutes.count
            ),
            customRouteCount: monitorLoop.customRouteCount,
            bypassRouteCount: monitorLoop.bypassRouteCount,
            lastRefresh: monitorLoop.lastRefresh,
            networkSignature: NetworkDetector.getNetworkSignature(),
            version: "1.0",
            officeMode: monitorLoop.officeMode,
            officeSwitchName: monitorLoop.officeSwitchName,
            officeWifiGateway: monitorLoop.officeDetector.wifiGateway
        )

        do {
            let data = try JSONEncoder().encode(status)
            reply(data)
        } catch {
            logger.error("Failed to encode status: \(error.localizedDescription)")
            reply(Data())
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
        reply("1.0")
    }
}
