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

    static func statusNetworkSignature() -> StatusProbe<String?> {
        let route = ShellRunner.runStatus("/sbin/route", arguments: ["-n", "get", "default"])
        guard route.exitCode == 0, let output = route.output else { return .failure }

        let gateway = parse(field: "gateway", from: output) ?? "none"
        let iface = parse(field: "interface", from: output) ?? "none"
        guard iface != "none" else { return .success("\(gateway):none:none") }

        let ifconfig = ShellRunner.runStatus("/sbin/ifconfig", arguments: [iface])
        guard ifconfig.exitCode == 0, let ifconfigOutput = ifconfig.output else { return .failure }
        return .success("\(gateway):\(iface):\(parseInterfaceIP(ifconfigOutput) ?? "none")")
    }

    private static func parseRouteGetDefault(field: String) -> String? {
        let (output, _) = ShellRunner.run("/sbin/route", arguments: ["-n", "get", "default"])
        guard let output else { return nil }
        return parse(field: field, from: output)
    }

    private static func parse(field: String, from output: String) -> String? {
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
        return parseInterfaceIP(output)
    }

    private static func parseInterfaceIP(_ output: String) -> String? {
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
