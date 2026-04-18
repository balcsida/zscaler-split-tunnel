import Foundation
import os

/// Spike: PF-based replacement for `BroadRouteManager` + per-destination
/// `/sbin/route add` manipulation.
///
/// Not wired into `MonitorLoop` or `XPCProtocol`. The module stands alone so
/// the approach can be validated before committing to a full integration.
///
/// Mechanism:
/// - Rules load into `com.apple/050.zscaler-split-tunnel`, which `/etc/pf.conf`
///   auto-evaluates via its `anchor "com.apple/*"` wildcard. No pf.conf edit
///   is required, and Apple-signed macOS updates won't strip the anchor.
/// - The `050.` prefix sorts our rules before Apple's `200.AirDrop/*` and
///   `250.ApplicationFirewall/*` entries so we run first.
/// - `pass out quick route-to (iface gw) reply-to (iface gw)` overrides the
///   kernel's default-route decision at packet time *without* deleting
///   Zscaler's broad routes. `reply-to` is mandatory — without it, return
///   traffic still tries to exit via the RIB-chosen default and the handshake
///   breaks.
/// - `pfctl -E` is reference-counted system-wide; `release()` decrements via
///   the stored token so AirDrop and other PF users are undisturbed.
///
/// Manual test procedure (run from the root helper or sudo shell):
/// 1. Pick a destination currently routing through Zscaler:
///    `IP=$(dig +short google.com | head -1)`
///    `route -n get $IP | grep interface` → expect `utun*`.
/// 2. Invoke `PFRouteEngine.enable()` then `PFRouteEngine.apply(...)` with
///    `$IP` in `bypassV4` and the current en0 gateway from
///    `route -n get default | grep gateway`.
/// 3. `route -n get $IP` will *still* show Zscaler (PF does not touch the
///    RIB). But `tcpdump -ni en0 host $IP` should show SYN leaving en0.
/// 4. `curl -v --resolve google.com:443:$IP https://google.com/` — if the
///    handshake completes, `reply-to` is correct. If SYN leaves but no
///    SYN/ACK returns, `reply-to` is wrong (most common spike failure).
/// 5. `PFRouteEngine.flushAnchor()` then `PFRouteEngine.release()` to tear
///    down. Verify `pfctl -s info` still shows PF `Status: Enabled` if
///    another component (AirDrop) holds a reference, or `Disabled` otherwise.
enum PFRouteEngine {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "PFRouteEngine")
    private static let anchor = "com.apple/050.zscaler-split-tunnel"
    /// Spike-grade: only written from the helper's serialized XPC handlers,
    /// so concurrent writes are not expected in practice. A production
    /// integration should wrap this in a lock or hand ownership to an actor.
    nonisolated(unsafe) private static var enableToken: String?

    // MARK: - PF enable/release (reference-counted)

    /// Enables PF and stores the token for later release. Idempotent.
    static func enable() -> Bool {
        guard enableToken == nil else { return true }
        let result = ShellRunner.runCapturingStderr("/sbin/pfctl", arguments: ["-E"])
        // `pfctl -E` writes the token to stderr. Format varies across macOS
        // releases but always contains "Token : <digits>".
        guard let token = parseToken(from: result.stderr + "\n" + result.stdout) else {
            logger.error("pfctl -E failed (exit=\(result.exitCode, privacy: .public)): \(result.stderr, privacy: .public)")
            return false
        }
        enableToken = token
        logger.info("Enabled PF (token=\(token, privacy: .public))")
        return true
    }

    /// Releases our PF reference. Safe to call if we never enabled.
    static func release() -> Bool {
        guard let token = enableToken else { return true }
        let result = ShellRunner.runCapturingStderr("/sbin/pfctl", arguments: ["-X", token])
        guard result.exitCode == 0 else {
            logger.error("pfctl -X \(token, privacy: .public) failed: \(result.stderr, privacy: .public)")
            return false
        }
        enableToken = nil
        logger.info("Released PF token \(token, privacy: .public)")
        return true
    }

    // MARK: - Anchor lifecycle

    /// Writes the ruleset into a temp file, loads it into our anchor, and
    /// populates the four destination tables. Any nil/empty gateway or
    /// interface causes the corresponding rules to be omitted — partial
    /// rulesets are better than failed loads when e.g. IPv6 has no default.
    static func apply(
        physInterface: String?,
        physGatewayV4: String?,
        physGatewayV6: String?,
        zscalerInterface: String?,
        bypassV4: [String] = [],
        bypassV6: [String] = [],
        forcedV4: [String] = [],
        forcedV6: [String] = []
    ) -> Bool {
        let ruleset = buildRuleset(
            physInterface: physInterface,
            physGatewayV4: physGatewayV4,
            physGatewayV6: physGatewayV6,
            zscalerInterface: zscalerInterface
        )

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zscaler-pf-\(UUID().uuidString).conf")
        do {
            try ruleset.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write temp anchor file: \(error.localizedDescription, privacy: .public)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let load = ShellRunner.runCapturingStderr(
            "/sbin/pfctl",
            arguments: ["-a", anchor, "-f", tempURL.path]
        )
        guard load.exitCode == 0 else {
            logger.error("pfctl -a \(anchor, privacy: .public) -f … failed: \(load.stderr, privacy: .public)")
            return false
        }

        var allOK = true
        allOK = populateTable("bypass_v4", entries: bypassV4) && allOK
        allOK = populateTable("bypass_v6", entries: bypassV6) && allOK
        allOK = populateTable("forced_v4", entries: forcedV4) && allOK
        allOK = populateTable("forced_v6", entries: forcedV6) && allOK

        logger.info("Applied PF anchor (bypass v4=\(bypassV4.count) v6=\(bypassV6.count), forced v4=\(forcedV4.count) v6=\(forcedV6.count))")
        return allOK
    }

    /// Removes all rules and table entries from our anchor. Leaves PF enabled.
    static func flushAnchor() -> Bool {
        let result = ShellRunner.runCapturingStderr("/sbin/pfctl", arguments: ["-a", anchor, "-F", "all"])
        if result.exitCode == 0 {
            logger.info("Flushed anchor \(anchor, privacy: .public)")
            return true
        }
        logger.error("Flush \(anchor, privacy: .public) failed: \(result.stderr, privacy: .public)")
        return false
    }

    /// Dry-run: returns the ruleset string that `apply` would load. Useful for
    /// eyeballing before touching PF, or for `pfctl -nf <path>` syntax checks.
    static func previewRuleset(
        physInterface: String?,
        physGatewayV4: String?,
        physGatewayV6: String?,
        zscalerInterface: String?
    ) -> String {
        buildRuleset(
            physInterface: physInterface,
            physGatewayV4: physGatewayV4,
            physGatewayV6: physGatewayV6,
            zscalerInterface: zscalerInterface
        )
    }

    // MARK: - Private

    private static func buildRuleset(
        physInterface: String?,
        physGatewayV4: String?,
        physGatewayV6: String?,
        zscalerInterface: String?
    ) -> String {
        var lines: [String] = [
            "# Auto-generated by PFRouteEngine. Loaded into \(anchor).",
            "table <bypass_v4> persist",
            "table <bypass_v6> persist",
            "table <forced_v4> persist",
            "table <forced_v6> persist",
            "",
        ]

        if let iface = physInterface, let gw = physGatewayV4 {
            lines.append("pass out quick route-to (\(iface) \(gw)) reply-to (\(iface) \(gw)) inet from any to <bypass_v4>")
        }
        if let iface = physInterface, let gw = physGatewayV6 {
            lines.append("pass out quick route-to (\(iface) \(gw)) reply-to (\(iface) \(gw)) inet6 from any to <bypass_v6>")
        }
        if let iface = zscalerInterface {
            lines.append("pass out quick route-to \(iface) inet from any to <forced_v4>")
            lines.append("pass out quick route-to \(iface) inet6 from any to <forced_v6>")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func populateTable(_ table: String, entries: [String]) -> Bool {
        guard !entries.isEmpty else { return true }
        var args = ["-a", anchor, "-t", table, "-T", "replace"]
        args.append(contentsOf: entries)
        let result = ShellRunner.runCapturingStderr("/sbin/pfctl", arguments: args)
        if result.exitCode != 0 {
            logger.error("pfctl -t \(table, privacy: .public) -T replace failed: \(result.stderr, privacy: .public)")
            return false
        }
        return true
    }

    private static func parseToken(from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            guard let range = line.range(of: "Token :") else { continue }
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let digits = tail.prefix(while: { $0.isNumber })
            if !digits.isEmpty { return String(digits) }
        }
        return nil
    }
}
