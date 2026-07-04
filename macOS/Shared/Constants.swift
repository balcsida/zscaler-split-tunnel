import Foundation

enum AppConstants {
    static let appBundleID = "com.zscaler-split-tunnel.app"
    static let helperBundleID = "com.zscaler-split-tunnel.helper"
    static let machServiceName = helperBundleID

    static let ipv4BroadRoutes = [
        "1",
        "2/7",
        "4/6",
        "8/5",
        "11",
        "16/4",
        "32/3",
        "64/2",
        "128/2",
        "192/2",
    ]

    static let ipv6BroadRoutes = [
        "2000::/3",
        "fc00::/7",
        "::/1",
        "8000::/1",
    ]

    static let zscalerProcessNames = ["Zscaler", "ZSTunnel", "ZSTray", "ZTunnelService"]
    static let zscalerAppPath = "/Applications/Zscaler/Zscaler.app"
    static let zscalerProbeAddress = "100.64.1.3"

    static let defaultMonitorInterval: Int = 30
    static let statusPollInterval: TimeInterval = 5
    /// Freshness window between DNS re-queries per domain. Kept short so
    /// rotating domains reveal their sibling IPs quickly; accumulation with
    /// `dnsRetentionSeconds` prevents route flapping between answers.
    static let cacheExpireSeconds: Int = 300
    /// How long a resolved IP stays in the bypass set after it was last seen
    /// in a DNS answer. Rotating domains return one sibling per query, so
    /// IPs must outlive individual answers to keep full coverage.
    static let dnsRetentionSeconds: Int = 86400
    static let negativeCacheExpireSeconds: Int = 60
    static let remoteCacheExpireSeconds: Int = 3600
}
