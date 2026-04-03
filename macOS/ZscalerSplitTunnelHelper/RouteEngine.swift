import Foundation
import os

enum RouteEngine {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "RouteEngine")

    static func addRoute(destination: String, interface: String, isIPv6: Bool) -> Bool {
        let flag = isIPv6 ? "-inet6" : "-net"
        let exitCode = ShellRunner.runSilent("/sbin/route", arguments: ["-n", "add", flag, destination, "-interface", interface])
        if exitCode == 0 {
            logger.info("Added route \(destination) via interface \(interface)")
        } else {
            logger.warning("Failed to add route \(destination) via interface \(interface)")
        }
        return exitCode == 0
    }

    static func addBypassRoute(destination: String, gateway: String, isIPv6: Bool) -> Bool {
        let flag = isIPv6 ? "-inet6" : "-net"
        let exitCode = ShellRunner.runSilent("/sbin/route", arguments: ["-n", "add", flag, destination, "-gateway", gateway])
        if exitCode == 0 {
            logger.info("Added bypass route \(destination) via gateway \(gateway)")
        } else {
            logger.warning("Failed to add bypass route \(destination) via gateway \(gateway)")
        }
        return exitCode == 0
    }

    static func deleteRoute(destination: String, isIPv6: Bool) -> Bool {
        let flag = isIPv6 ? "-inet6" : "-net"
        let exitCode = ShellRunner.runSilent("/sbin/route", arguments: ["-n", "delete", flag, destination])
        if exitCode == 0 {
            logger.info("Deleted route \(destination)")
        }
        return exitCode == 0
    }

    static func routeExists(destination: String, isIPv6: Bool) -> Bool {
        let family = isIPv6 ? "inet6" : "inet"
        let (output, _) = ShellRunner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", family])
        guard let output else { return false }
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix(destination) {
                let afterDest = line.dropFirst(destination.count)
                if afterDest.isEmpty || afterDest.first?.isWhitespace == true {
                    return true
                }
            }
        }
        return false
    }

    static func getDefaultGateway() -> String? {
        let (output, _) = ShellRunner.run("/sbin/route", arguments: ["-n", "get", "default"])
        guard let output else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                let value = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func getDefaultInterface() -> String? {
        let (output, _) = ShellRunner.run("/sbin/route", arguments: ["-n", "get", "default"])
        guard let output else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let value = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func detectZscalerInterface() -> String? {
        let (output, _) = ShellRunner.run("/sbin/route", arguments: ["-n", "get", AppConstants.zscalerProbeAddress])
        guard let output else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let value = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
