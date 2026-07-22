import Foundation
import os

enum BroadRouteManager {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "BroadRouteManager")

    static func removeBroadRoutes() -> Int {
        var removedCount = 0

        for route in AppConstants.ipv4BroadRoutes {
            if RouteEngine.deleteRoute(destination: route, isIPv6: false) {
                removedCount += 1
            }
        }

        for route in AppConstants.ipv6BroadRoutes {
            if RouteEngine.deleteRoute(destination: route, isIPv6: true) {
                removedCount += 1
            }
        }

        // Remove default IPv6 route through Zscaler interface
        if let zscalerInterface = RouteEngine.detectZscalerInterface() {
            let exitCode = ShellRunner.runSilent("/sbin/route",
                arguments: ["-n", "delete", "-inet6", "default", "-interface", zscalerInterface])
            if exitCode == 0 {
                logger.info("Removed default IPv6 route through \(zscalerInterface)")
                removedCount += 1
            }
        }

        if removedCount > 0 {
            logger.info("Removed \(removedCount) broad routes")
        }
        return removedCount
    }

    static func countPresentRoutes() -> (ipv4: Int, ipv6: Int) {
        let ipv4 = countMatches(routes: AppConstants.ipv4BroadRoutes, family: "inet")
        let ipv6 = countMatches(routes: AppConstants.ipv6BroadRoutes, family: "inet6")
        return (ipv4, ipv6)
    }

    static func statusRouteCounts() -> StatusProbe<(ipv4: Int, ipv6: Int)> {
        let ipv4 = ShellRunner.runStatus("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        let ipv6 = ShellRunner.runStatus("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet6"])
        guard ipv4.exitCode == 0, let ipv4Output = ipv4.output,
              ipv6.exitCode == 0, let ipv6Output = ipv6.output else {
            return .failure
        }
        return .success((
            countMatches(routes: AppConstants.ipv4BroadRoutes, output: ipv4Output),
            countMatches(routes: AppConstants.ipv6BroadRoutes, output: ipv6Output)
        ))
    }

    private static func countMatches(routes: [String], family: String) -> Int {
        let (output, _) = ShellRunner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", family])
        guard let output else { return 0 }
        return countMatches(routes: routes, output: output)
    }

    private static func countMatches(routes: [String], output: String) -> Int {
        let lines = output.components(separatedBy: "\n")
        var count = 0
        for route in routes {
            for line in lines {
                if line.hasPrefix(route) {
                    let afterDest = line.dropFirst(route.count)
                    if afterDest.isEmpty || afterDest.first?.isWhitespace == true {
                        count += 1
                        break
                    }
                }
            }
        }
        return count
    }
}
