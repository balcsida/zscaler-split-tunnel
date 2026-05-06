import Foundation
import os

/// Recovers from a wedged routing table after Zscaler leaves stale state behind.
///
/// The two failure modes we see in the wild:
/// 1. IPv6 defaults stay pinned to dead `utunX` interfaces with `UGcIg` flags.
///    `route -n flush` will not remove these (they are ifscope-bound and the
///    utun iface is still up), so IPv6 has no usable global default and Happy
///    Eyeballs requests (e.g. claude.ai) fail with ERR_ADDRESS_INVALID.
/// 2. Direct override `/32`s pinned to a gateway from a previous network (e.g. an office
///    Wi-Fi gateway) persist after the user moves to a new network. Flush
///    removes these; the monitor re-adds them through the current gateway on
///    its next cycle.
///
/// Recovery runs four passes, in order:
///   1. Explicitly delete any default routes (v4 and v6) scoped to `utun*`.
///   2. `route -n flush` several times for anything else (including stale
///      direct override /32s).
///   3. Renew DHCP on each active en* service (`-setdhcp`). The flush dropped
///      the IPv4 default route — without this, Zscaler can't even reach its
///      brokers and traffic to anything outside the LAN dies with
///      "Network is unreachable".
///   4. Cycle IPv6 config on each active en* service (`-setv6off` /
///      `-setv6automatic`). Forces a Router Solicitation and fresh RA
///      processing so the IPv6 default reinstalls via en0.
///
/// Both refresh steps go through SystemConfiguration rather than `ifconfig`,
/// so the underlying Wi-Fi association/Ethernet link stays up and the blip on
/// each stack is short (~1s).
enum RouteReset {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "RouteReset")

    struct Result: Sendable {
        let flushAttempts: Int
        let bouncedServices: [String]
        let clearedTunnelDefaults: [String]
        let errors: [String]
    }

    static func run() -> Result {
        logger.info("Resetting routing table")

        var errors: [String] = []

        let clearedTunnelDefaults = removeStaleTunnelDefaults()
        if !clearedTunnelDefaults.isEmpty {
            logger.info("Cleared stale default routes on: \(clearedTunnelDefaults, privacy: .public)")
        }

        // Flush the routing table a few times; `route -n flush` is idempotent and does
        // not always remove everything in one pass because some entries repopulate.
        let flushRounds = 5
        for i in 0..<flushRounds {
            let res = ShellRunner.runCapturingStderr("/sbin/route", arguments: ["-n", "flush"])
            if res.exitCode != 0, !res.stderr.isEmpty {
                logger.warning("route flush pass \(i + 1, privacy: .public) stderr: \(res.stderr, privacy: .public)")
            }
        }

        let services = activeNetworkServices()
        logger.info("Refreshing IPv4+IPv6 on active network services: \(services.map(\.service), privacy: .public)")
        var bouncedServices: [String] = []

        for svc in services {
            // IPv4 first: the route flush dropped the default route. `-setdhcp`
            // triggers an immediate DHCP renewal (without an explicit "off"
            // step), which reinstalls the default. Without this, Zscaler can't
            // reach its brokers and the tunnel never comes up — every TCP
            // connect fails with "Network is unreachable".
            let v4 = ShellRunner.runCapturingStderr("/usr/sbin/networksetup",
                arguments: ["-setdhcp", svc.service])
            if v4.exitCode != 0 {
                let msg = "networksetup -setdhcp '\(svc.service)' failed: \(v4.stderr)"
                logger.warning("\(msg, privacy: .public)")
                errors.append(msg)
                continue
            }

            // IPv6: cycle to force RS + fresh RA processing so the IPv6
            // default reinstalls via en0 instead of staying pinned to a
            // dead utun.
            let v6off = ShellRunner.runCapturingStderr("/usr/sbin/networksetup",
                arguments: ["-setv6off", svc.service])
            if v6off.exitCode != 0 {
                let msg = "networksetup -setv6off '\(svc.service)' failed: \(v6off.stderr)"
                logger.warning("\(msg, privacy: .public)")
                errors.append(msg)
                continue
            }
            // Brief pause so SC registers the v6 teardown before we re-enable.
            Thread.sleep(forTimeInterval: 0.5)
            let v6on = ShellRunner.runCapturingStderr("/usr/sbin/networksetup",
                arguments: ["-setv6automatic", svc.service])
            if v6on.exitCode != 0 {
                let msg = "networksetup -setv6automatic '\(svc.service)' failed: \(v6on.stderr)"
                logger.warning("\(msg, privacy: .public)")
                errors.append(msg)
                continue
            }
            bouncedServices.append(svc.service)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Belt-and-suspenders: SystemConfiguration sometimes doesn't reinstall
        // the global IPv6 default after `-setv6automatic`, particularly when
        // stale utun static router entries (`flags=IST`) remain in the NDP
        // default-router list. If the table is still empty, pick a real
        // en*-attached router from `ndp -rn` and install it ourselves.
        if installIPv6DefaultIfMissing() {
            logger.info("Installed IPv6 default route from NDP cache")
        }

        logger.info("Route reset complete (cleared \(clearedTunnelDefaults.count, privacy: .public) tunnel defaults, cycled \(bouncedServices.count, privacy: .public) services, \(errors.count, privacy: .public) errors)")
        return Result(
            flushAttempts: flushRounds,
            bouncedServices: bouncedServices,
            clearedTunnelDefaults: clearedTunnelDefaults,
            errors: errors
        )
    }

    // MARK: - IPv6 default rescue

    /// Returns true if it had to install a default route (i.e. the table was
    /// missing one and an en*-attached router was available in NDP).
    private static func installIPv6DefaultIfMissing() -> Bool {
        let check = ShellRunner.runCapturingStderr("/sbin/route",
            arguments: ["-n", "get", "-inet6", "default"])
        if check.exitCode == 0 && check.stdout.contains("gateway:") {
            return false
        }

        let ndp = ShellRunner.runCapturingStderr("/usr/sbin/ndp", arguments: ["-rn"])
        guard ndp.exitCode == 0 else { return false }

        // Lines look like:
        //   fe80::962a:6fff:feca:9068%en0 if=en0, flags=T, pref=high, expire=29m52s
        //   fe80::%utun0 if=utun0, flags=IST, pref=medium, expire=Never
        // Pick the first router whose scope is an en* interface (skip utun).
        for line in ndp.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let gateway = trimmed.split(separator: " ").first else { continue }
            let gw = String(gateway)
            // Only accept routers attached to an en* interface; utun routers
            // are exactly the stale entries we're trying to work around.
            guard let pctIdx = gw.firstIndex(of: "%") else { continue }
            let scope = gw[gw.index(after: pctIdx)...]
            guard scope.hasPrefix("en") else { continue }

            let add = ShellRunner.runCapturingStderr("/sbin/route",
                arguments: ["-n", "add", "-inet6", "default", gw])
            if add.exitCode == 0 {
                return true
            }
            logger.warning("route add -inet6 default \(gw, privacy: .public) failed: \(add.stderr, privacy: .public)")
        }
        return false
    }

    // MARK: - Stale tunnel-default cleanup

    /// Deletes any `default` routes (v4 and v6) scoped to a `utun*` interface.
    ///
    /// Zscaler and other NetworkExtension-based tunnels install defaults with
    /// `UGcIg` flags tied to `utunX`. When the tunnel process crashes the
    /// interface stays `UP,POINTOPOINT` and the ifscoped default lingers. The
    /// presence of any ifscoped default blocks the kernel from accepting a
    /// fresh RA-based default on en0, so IPv6 is stuck without a usable route.
    ///
    /// We try both `-ifscope` and `-interface` forms because which is effective
    /// depends on how the route was inserted, and `route delete` is harmless if
    /// the route isn't present.
    private static func removeStaleTunnelDefaults() -> [String] {
        var cleared: [String] = []
        for iface in tunnelInterfaces() {
            var anyDeleted = false
            for family in ["-inet6", "-inet"] {
                let ifscope = ShellRunner.runCapturingStderr("/sbin/route",
                    arguments: ["-n", "delete", family, "default", "-ifscope", iface])
                if ifscope.exitCode == 0 {
                    logger.info("Deleted default \(family, privacy: .public) -ifscope \(iface, privacy: .public)")
                    anyDeleted = true
                }
                let byIface = ShellRunner.runCapturingStderr("/sbin/route",
                    arguments: ["-n", "delete", family, "default", "-interface", iface])
                if byIface.exitCode == 0 {
                    logger.info("Deleted default \(family, privacy: .public) -interface \(iface, privacy: .public)")
                    anyDeleted = true
                }
            }
            if anyDeleted {
                cleared.append(iface)
            }
        }
        return cleared
    }

    private static func tunnelInterfaces() -> [String] {
        let result = ShellRunner.runCapturingStderr("/sbin/ifconfig", arguments: ["-l"])
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.hasPrefix("utun") && !$0.isEmpty }
    }

    // MARK: - Network service cycling

    struct ActiveService: Sendable {
        let service: String
        let device: String
    }

    /// Parses `networksetup -listnetworkserviceorder` and returns enabled
    /// services whose device is an `en*` interface currently reporting
    /// `status: active`. We restrict to `en*` to avoid bouncing virtual
    /// services (iPhone USB tether, Thunderbolt Bridge, etc.) that could
    /// surprise the user.
    private static func activeNetworkServices() -> [ActiveService] {
        let order = ShellRunner.runCapturingStderr("/usr/sbin/networksetup",
            arguments: ["-listnetworkserviceorder"])
        guard order.exitCode == 0 else {
            logger.warning("networksetup -listnetworkserviceorder failed: \(order.stderr, privacy: .public)")
            return []
        }

        // The output alternates service lines with a following hardware-port
        // line, e.g.:
        //   (1) Wi-Fi
        //   (Hardware Port: Wi-Fi, Device: en0)
        // Disabled services are prefixed with an asterisk: "(*) Name".
        var services: [ActiveService] = []
        var pendingService: String?

        for line in order.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("(Hardware Port:") {
                defer { pendingService = nil }
                guard let service = pendingService,
                      let deviceRange = trimmed.range(of: "Device: ") else { continue }
                let tail = trimmed[deviceRange.upperBound...]
                let device = tail.prefix { $0 != ")" && !$0.isWhitespace }
                let deviceName = String(device)
                guard !deviceName.isEmpty, isEnInterfaceActive(deviceName) else { continue }
                services.append(ActiveService(service: service, device: deviceName))
            } else if trimmed.hasPrefix("("), let closeParen = trimmed.firstIndex(of: ")") {
                let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<closeParen]
                if tag == "*" {
                    pendingService = nil
                    continue
                }
                let name = trimmed[trimmed.index(after: closeParen)...]
                    .trimmingCharacters(in: .whitespaces)
                pendingService = name.isEmpty ? nil : name
            }
        }
        return services
    }

    private static func isEnInterfaceActive(_ device: String) -> Bool {
        guard device.hasPrefix("en"), device.dropFirst(2).allSatisfy(\.isNumber) else { return false }
        let result = ShellRunner.runCapturingStderr("/sbin/ifconfig", arguments: [device])
        guard result.exitCode == 0 else { return false }
        for line in result.stdout.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "status: active" {
                return true
            }
        }
        return false
    }
}
