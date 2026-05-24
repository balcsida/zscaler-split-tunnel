import Foundation
import os

enum RouteEngine {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "RouteEngine")

    static func addRoute(destination: String, interface: String, isIPv6: Bool) -> Bool {
        let flag = isIPv6 ? "-inet6" : "-net"
        let result = ShellRunner.runCapturingStderr("/sbin/route",
            arguments: ["-n", "add", flag, destination, "-interface", interface])
        if result.exitCode == 0 {
            logger.info("Added route \(destination, privacy: .public) via interface \(interface, privacy: .public)")
        } else {
            logger.warning("Failed to add route \(destination, privacy: .public) via interface \(interface, privacy: .public) (exit=\(result.exitCode, privacy: .public)): \(result.stderr, privacy: .public)")
        }
        return result.exitCode == 0
    }

    static func addBypassRoute(destination: String, gateway: String, isIPv6: Bool) -> Bool {
        let flag = isIPv6 ? "-inet6" : "-net"
        let result = ShellRunner.runCapturingStderr("/sbin/route",
            arguments: ["-n", "add", flag, destination, "-gateway", gateway])
        if result.exitCode == 0 {
            logger.info("Added direct override \(destination, privacy: .public) via gateway \(gateway, privacy: .public)")
            return true
        }

        if isRouteAlreadyPresentError(stdout: result.stdout, stderr: result.stderr) {
            logger.debug("Direct override \(destination, privacy: .public) already exists via gateway \(gateway, privacy: .public)")
            return true
        }

        logger.warning("Failed to add direct override \(destination, privacy: .public) via gateway \(gateway, privacy: .public) (exit=\(result.exitCode, privacy: .public)): \(result.stderr, privacy: .public)")
        return false
    }

    static func deleteRoute(destination: String, isIPv6: Bool) -> Bool {
        let flag = isIPv6 ? "-inet6" : "-net"
        let result = ShellRunner.runCapturingStderr("/sbin/route",
            arguments: ["-n", "delete", flag, destination])
        if result.exitCode == 0 {
            logger.info("Deleted route \(destination, privacy: .public)")
        }
        return result.exitCode == 0
    }

    /// Replaces any existing route to `destination` with a fresh one via `gateway`.
    /// Best-effort delete then add — handles the stale-gateway case on network change
    /// where `routeExists` would otherwise leave an entry pinned to the old gateway.
    static func replaceBypassRoute(destination: String, gateway: String, isIPv6: Bool) -> Bool {
        _ = deleteRoute(destination: destination, isIPv6: isIPv6)
        return addBypassRoute(destination: destination, gateway: gateway, isIPv6: isIPv6)
    }

    /// Replaces any existing route to `destination` with a fresh one via `interface`.
    /// Custom routes always go through this path so a cloned `WASCLONED` /32 left
    /// over on the default interface (created when the kernel beats the helper to
    /// the first packet) cannot fool `routeExists` into skipping the install.
    static func replaceRoute(destination: String, interface: String, isIPv6: Bool) -> Bool {
        _ = deleteRoute(destination: destination, isIPv6: isIPv6)
        return addRoute(destination: destination, interface: interface, isIPv6: isIPv6)
    }

    static func routeExists(destination: String, isIPv6: Bool) -> Bool {
        // `netstat -rn` abbreviates IPv4 host routes such as 34.128.128.0/32 to
        // `34.128.128/32`, so string-prefix matching misses existing direct
        // overrides and the helper re-adds them every monitor cycle. `route get`
        // returns the canonical destination/mask and lets us distinguish a real
        // installed route from the inherited default route.
        if routeGetShowsInstalledRoute(destination: destination, gateway: nil, isIPv6: isIPv6) {
            return true
        }

        let family = isIPv6 ? "inet6" : "inet"
        let (output, _) = ShellRunner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", family])
        guard let output else { return false }
        let candidates = netstatDestinationCandidates(for: destination)
        for line in output.components(separatedBy: "\n") {
            for candidate in candidates where line.hasPrefix(candidate) {
                let afterDest = line.dropFirst(candidate.count)
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

    /// Removes stale cloned host routes left over from a previous IP address.
    /// When the local IP changes (e.g. DHCP at a new network), the kernel's
    /// cloned /32 and /128 entries retain the old preferred source address,
    /// causing `EADDRNOTAVAIL` (errno 49) for every new TCP connection to
    /// those destinations. Deleting them here lets the kernel re-clone them
    /// with the correct source address when routes are reinstalled.
    ///
    /// Scans all interfaces rather than scoping to the current default: when
    /// the default interface itself just changed, the stale clones live on
    /// the previous interface. `utun*` and ARP/NDP neighbor-cache entries
    /// are skipped.
    static func flushStaleHostRoutes() {
        flushStaleHostRoutes(family: "inet",  suffix: "/32",  familyFlag: nil)
        flushStaleHostRoutes(family: "inet6", suffix: "/128", familyFlag: "-inet6")
    }

    private static func flushStaleHostRoutes(family: String, suffix: String, familyFlag: String?) {
        let (output, _) = ShellRunner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", family])
        guard let output else { return }
        var flushed = 0
        for line in output.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            // netstat columns: Destination Gateway Flags Netif [Expire]
            guard cols.count >= 4 else { continue }
            let dest    = String(cols[0])
            let gateway = String(cols[1])
            let flags   = String(cols[2])
            let netif   = String(cols[3])
            guard dest.hasSuffix(suffix),
                  flags.contains("H"),
                  flags.contains("W")
            else { continue }
            // Tunnel routes are managed separately and don't suffer from the
            // source-address-binding issue.
            if netif.hasPrefix("utun") { continue }
            // ARP/NDP neighbor-cache entries share the H+W pattern but their
            // gateway is a link-layer address. Deleting them is harmless but
            // causes unnecessary LAN churn (forces re-resolution).
            if isLinkLayerGateway(gateway) { continue }
            var args = ["-n", "delete"]
            if let familyFlag { args.append(familyFlag) }
            args.append(contentsOf: ["-host", dest])
            let result = ShellRunner.runCapturingStderr("/sbin/route", arguments: args)
            if result.exitCode == 0 {
                logger.info("Flushed stale cloned host route \(dest, privacy: .public) on \(netif, privacy: .public)")
                flushed += 1
            } else {
                logger.debug("Failed to flush \(dest, privacy: .public) on \(netif, privacy: .public): \(result.stderr, privacy: .public)")
            }
        }
        if flushed > 0 {
            logger.info("Flushed \(flushed) stale cloned host route(s) (\(family, privacy: .public))")
        }
    }

    static func routeExists(destination: String, gateway: String, isIPv6: Bool) -> Bool {
        if routeGetShowsInstalledRoute(destination: destination, gateway: gateway, isIPv6: isIPv6) {
            return true
        }
        return false
    }

    private static func routeGetShowsInstalledRoute(destination: String, gateway expectedGateway: String?, isIPv6: Bool) -> Bool {
        let routeTarget = destination.split(separator: "/", maxSplits: 1).first.map(String.init) ?? destination
        var args = ["-n", "get"]
        if isIPv6 { args.append("-inet6") }
        args.append(routeTarget)

        let (output, exitCode) = ShellRunner.run("/sbin/route", arguments: args)
        guard exitCode == 0, let output else { return false }

        var reportedDestination: String?
        var reportedGateway: String?
        var mask: String?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("destination:") {
                reportedDestination = trimmed.dropFirst("destination:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("gateway:") {
                reportedGateway = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("mask:") {
                mask = trimmed.dropFirst("mask:".count).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let reportedDestination, reportedDestination != "default" else { return false }
        if let expectedGateway, reportedGateway != expectedGateway {
            return false
        }

        if let slash = destination.firstIndex(of: "/") {
            let address = String(destination[..<slash])
            let prefix = String(destination[destination.index(after: slash)...])
            if prefix == "32" || prefix == "128" {
                return reportedDestination == address
            }
            if !isIPv6, let expectedMask = ipv4Mask(forPrefix: prefix) {
                return mask == expectedMask
            }
        }

        return reportedDestination == destination
    }

    private static func netstatDestinationCandidates(for destination: String) -> Set<String> {
        var candidates: Set<String> = [destination]
        if destination.hasSuffix("/32") {
            let host = String(destination.dropLast(3))
            candidates.insert(host)
            candidates.insert(abbreviatedIPv4Host(host) + "/32")
        } else if !destination.contains("/") {
            candidates.insert(destination + "/32")
            candidates.insert(abbreviatedIPv4Host(destination) + "/32")
        }
        return candidates
    }

    private static func abbreviatedIPv4Host(_ host: String) -> String {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return host }
        while parts.last == "0", parts.count > 1 {
            parts.removeLast()
        }
        return parts.joined(separator: ".")
    }

    private static func ipv4Mask(forPrefix prefix: String) -> String? {
        guard let bits = Int(prefix), bits >= 0, bits <= 32 else { return nil }
        let mask = bits == 0 ? UInt32(0) : UInt32.max << UInt32(32 - bits)
        return [24, 16, 8, 0].map { shift in String((mask >> UInt32(shift)) & 0xff) }.joined(separator: ".")
    }

    private static func isRouteAlreadyPresentError(stdout: String, stderr: String) -> Bool {
        let message = "\(stdout)\n\(stderr)".lowercased()
        return message.contains("file exists") || message.contains("already in table")
    }

    /// Returns true if `gateway` is a link-layer address (`link#N` or a MAC)
    /// rather than an IP. Used to distinguish ARP/NDP neighbor-cache entries
    /// from routed host entries in `netstat -rn` output.
    private static func isLinkLayerGateway(_ gateway: String) -> Bool {
        if gateway.hasPrefix("link#") { return true }
        // MAC addresses have exactly 5 colons and no "::" (which IPv6
        // compressed form always has; uncompressed IPv6 has 7 colons).
        let colonCount = gateway.reduce(0) { $1 == ":" ? $0 + 1 : $0 }
        return colonCount == 5 && !gateway.contains("::")
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
