import Foundation
import os

/// Watches the routing table through `route -n monitor` and reports when a
/// broad route appears, so the sweep runs right away instead of on the next
/// monitor tick. Zscaler reinstalls its broad routes on every reconnect, and
/// until they are removed all traffic (Zscaler's own included) falls into a
/// tunnel that is not forwarding yet. With the 30s timer that outage lasted up
/// to 30s and Zscaler usually failed to reconnect inside it.
final class RouteTableMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.helperBundleID, category: "RouteTableMonitor")
    private var stream: ShellRunner.StreamingProcess?
    private var parser = Parser()

    func start(onBroadRouteAdded: @escaping @Sendable () -> Void) {
        guard stream == nil else { return }
        parser = Parser()
        do {
            // route(8) fully buffers stdout when it is a pipe, so the last message of
            // a burst could sit unread for minutes. A pty makes it line-buffered.
            stream = try ShellRunner.stream(
                "/usr/bin/script", arguments: ["-q", "/dev/null", "/sbin/route", "-n", "monitor"],
                onLine: { [weak self] line in
                    guard let self, let destination = self.parser.feed(line) else { return }
                    // notice: info lines are not persisted, and this is the line that proves the fix.
                    self.logger.notice("Broad route \(destination, privacy: .public) added, sweeping")
                    onBroadRouteAdded()
                },
                onExit: { [weak self] status in
                    self?.logger.error("route monitor exited (status \(status)); falling back to the periodic sweep")
                    self?.stream = nil
                }
            )
            logger.notice("Started routing table monitor")
        } catch {
            logger.error("Failed to start route monitor: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `cancel()` detaches the reader before terminating, so a following `start`
    /// never shares the parser with the old process.
    func stop() {
        stream?.cancel()
        stream = nil
    }

    /// Line-by-line parser for `route -n monitor` output. Returns the destination
    /// of an RTM_ADD message when it is one of Zscaler's broad routes.
    final class Parser {
        /// Destinations as `route -n monitor` prints them.
        static let broadDestinations: Set<String> = {
            var set = Set<String>()
            for route in AppConstants.ipv4BroadRoutes {
                var octets = route.split(separator: "/")[0].split(separator: ".").map(String.init)
                while octets.count < 4 { octets.append("0") }
                set.insert(octets.joined(separator: "."))
            }
            for route in AppConstants.ipv6BroadRoutes {
                set.insert(String(route.split(separator: "/")[0]))
            }
            set.insert("default") // IPv6 default added with `-interface utunN`
            return set
        }()

        private var inAdd = false
        private var expectAddresses = false

        func feed(_ line: String) -> String? {
            if line.hasPrefix("RTM_") {
                inAdd = line.hasPrefix("RTM_ADD:")
                expectAddresses = false
                return nil
            }
            guard inAdd else { return nil }
            if line.hasPrefix("sockaddrs:") {
                expectAddresses = line.contains("DST")
                return nil
            }
            guard expectAddresses else { return nil }
            expectAddresses = false
            inAdd = false
            let fields = line.split(separator: " ").map(String.init)
            guard let destination = fields.first, Self.broadDestinations.contains(destination) else { return nil }
            // Our own IPv6 default repair adds `::` via a link-local gateway on enN.
            if fields.contains(where: { $0.contains("%en") }) { return nil }
            return destination
        }
    }
}
