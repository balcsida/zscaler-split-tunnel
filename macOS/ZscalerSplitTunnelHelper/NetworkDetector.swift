import Foundation
import os

enum NetworkDetector {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "NetworkDetector")

    static func getNetworkSignature() -> String {
        let gateway = parseRouteGetDefault(field: "gateway") ?? "none"
        let iface = parseRouteGetDefault(field: "interface") ?? "none"
        let ipAddr = getInterfaceIP(iface) ?? "none"
        return "\(gateway):\(iface):\(ipAddr)"
    }

    private static func parseRouteGetDefault(field: String) -> String? {
        let (output, _) = ShellRunner.run("/sbin/route", arguments: ["-n", "get", "default"])
        guard let output else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(field):") {
                let value = trimmed.dropFirst(field.count + 1).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func getInterfaceIP(_ iface: String) -> String? {
        guard iface != "none" else { return nil }
        let (output, _) = ShellRunner.run("/sbin/ifconfig", arguments: [iface])
        guard let output else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2 {
                    return String(parts[1])
                }
            }
        }
        return nil
    }
}
