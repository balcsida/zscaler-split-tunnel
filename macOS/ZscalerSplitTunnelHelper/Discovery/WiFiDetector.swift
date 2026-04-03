import Foundation
import os

enum WiFiDetector {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "WiFiDetector")

    /// Returns the Wi-Fi interface name (e.g. "en0") by querying networksetup.
    static func wifiInterfaceName() -> String? {
        let (output, exitCode) = ShellRunner.run("/usr/sbin/networksetup", arguments: ["-listallhardwareports"])
        guard exitCode == 0, let output else { return nil }

        let lines = output.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if line.contains("Wi-Fi") || line.contains("AirPort") {
                if i + 1 < lines.count {
                    let deviceLine = lines[i + 1]
                    if deviceLine.hasPrefix("Device:") {
                        let device = deviceLine.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                        if !device.isEmpty { return device }
                    }
                }
            }
        }
        return nil
    }

    /// Returns the SSID currently associated on the given Wi-Fi interface.
    static func currentSSID(interface: String = "en0") -> String? {
        let (output, exitCode) = ShellRunner.run("/usr/sbin/networksetup", arguments: ["-getairportnetwork", interface])
        guard exitCode == 0, let output else { return nil }

        // Output: "Current Wi-Fi Network: MyNetwork"
        // or:     "You are not associated with an AirPort network."
        let prefix = "Current Wi-Fi Network: "
        guard output.hasPrefix(prefix) else { return nil }
        let ssid = String(output.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ssid.isEmpty ? nil : ssid
    }

    /// Returns the gateway IP for a specific interface using scoped route lookup.
    static func gateway(forInterface iface: String) -> String? {
        let (output, exitCode) = ShellRunner.run("/sbin/route", arguments: ["-n", "get", "default", "-ifscope", iface])
        guard exitCode == 0, let output else { return nil }

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                let value = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    logger.info("WiFi gateway on \(iface): \(value)")
                    return value
                }
            }
        }
        return nil
    }
}
