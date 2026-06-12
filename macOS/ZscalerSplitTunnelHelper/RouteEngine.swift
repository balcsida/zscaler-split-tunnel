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

    static func ensureBypassRoute(destination: String, gateway: String, isIPv6: Bool, forceReplace: Bool = false) -> Bool {
        ensureBypassRoute(
            destination: destination,
            gateway: gateway,
            isIPv6: isIPv6,
            forceReplace: forceReplace,
            expectedRouteExists: { destination, gateway, isIPv6 in
                routeExists(destination: destination, gateway: gateway, isIPv6: isIPv6)
            },
            anyRouteExists: { destination, isIPv6 in
                routeExists(destination: destination, isIPv6: isIPv6)
            },
            addRoute: { destination, gateway, isIPv6 in
                addBypassRoute(destination: destination, gateway: gateway, isIPv6: isIPv6)
            },
            replaceRoute: { destination, gateway, isIPv6 in
                replaceBypassRoute(destination: destination, gateway: gateway, isIPv6: isIPv6)
            }
        )
    }

    static func ensureBypassRoute(
        destination: String,
        gateway: String,
        isIPv6: Bool,
        forceReplace: Bool = false,
        expectedRouteExists: (String, String, Bool) -> Bool,
        anyRouteExists: (String, Bool) -> Bool,
        addRoute: (String, String, Bool) -> Bool,
        replaceRoute: (String, String, Bool) -> Bool
    ) -> Bool {
        if forceReplace {
            return replaceRoute(destination, gateway, isIPv6)
        }

        if expectedRouteExists(destination, gateway, isIPv6) {
            return true
        }

        if anyRouteExists(destination, isIPv6) {
            return replaceRoute(destination, gateway, isIPv6)
        }

        return addRoute(destination, gateway, isIPv6)
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

    @discardableResult
    static func flushStaleGatewayHostRoutes(
        expectedGateway: String,
        ownedDestinations: [String]? = nil
    ) -> Int {
        flushStaleGatewayHostRoutes(
            expectedGateway: expectedGateway,
            ownedDestinations: ownedDestinations,
            netstatOutput: {
                let (output, _) = ShellRunner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
                return output
            },
            deleteHostRoute: { host in
                let result = ShellRunner.runCapturingStderr("/sbin/route",
                    arguments: ["-n", "delete", "-host", host])
                if result.exitCode != 0 {
                    logger.debug("Failed to delete stale gateway host route \(host, privacy: .public): \(result.stderr, privacy: .public)")
                }
                return result.exitCode == 0
            }
        )
    }

    static func flushStaleGatewayHostRoutes(
        expectedGateway: String,
        ownedDestinations: [String]? = nil,
        netstatOutput: () -> String?,
        deleteHostRoute: (String) -> Bool
    ) -> Int {
        guard isIPv4Address(expectedGateway), let output = netstatOutput() else { return 0 }
        let ownedHosts = ownedDestinations.map(ownedIPv4HostRoutes)

        var flushed = 0
        for line in output.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            // netstat columns: Destination Gateway Flags Netif [Expire]
            guard cols.count >= 4 else { continue }
            let destination = String(cols[0])
            let gateway = String(cols[1])
            let flags = String(cols[2])
            let netif = String(cols[3])

            guard let host = hostAddress(fromIPv4HostRoute: destination),
                  gateway != expectedGateway,
                  ownedHosts?.contains(host) ?? true,
                  flags.contains("G"),
                  !netif.hasPrefix("utun"),
                  !isLinkLayerGateway(gateway),
                  isIPv4Address(gateway)
            else { continue }

            if deleteHostRoute(host) {
                logger.info("Deleted stale direct host route \(host, privacy: .public) via old gateway \(gateway, privacy: .public); expected \(expectedGateway, privacy: .public)")
                flushed += 1
            }
        }

        if flushed > 0 {
            logger.info("Deleted \(flushed) stale direct host route(s) via mismatched gateway")
        }
        return flushed
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

    private static func hostAddress(fromIPv4HostRoute destination: String) -> String? {
        guard destination.hasSuffix("/32") else { return nil }
        let host = String(destination.dropLast(3))
        if isIPv4Address(host) {
            return host
        }
        return expandedAbbreviatedIPv4Host(host)
    }

    private static func ownedIPv4HostRoutes(from destinations: [String]) -> Set<String> {
        Set(destinations.compactMap { destination in
            if destination.hasSuffix("/32") {
                return hostAddress(fromIPv4HostRoute: destination)
            }
            if !destination.contains("/"), isIPv4Address(destination) {
                return destination
            }
            return nil
        })
    }

    private static func expandedAbbreviatedIPv4Host(_ host: String) -> String? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        guard parts.allSatisfy({ part in
            guard let octet = Int(part), octet >= 0, octet <= 255 else { return false }
            return String(octet) == part
        }) else { return nil }

        while parts.count < 4 {
            parts.append("0")
        }
        return parts.joined(separator: ".")
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = Int(part), octet >= 0, octet <= 255 else { return false }
            return String(octet) == part
        }
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
