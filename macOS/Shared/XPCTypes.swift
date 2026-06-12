import Foundation

enum OfficeMode: String, Codable, Sendable {
    case disabled
    case detecting
    case officeWifi
    case officeNoWifi
    case notOffice
}

struct HelperStatus: Codable, Sendable {
    var isMonitoring: Bool
    var monitorInterval: Int
    var zscalerRunning: Bool
    var zscalerInterface: String?
    var broadRoutesPresent: BroadRouteStatus
    var customRouteCount: Int
    var bypassRouteCount: Int
    var lastRefresh: Date?
    var networkSignature: String?
    var version: String
    var officeMode: OfficeMode
    var officeSwitchName: String?
    var officeWifiGateway: String?
    var discoveredDevice: DiscoveredDeviceInfo?
    var captureStatus: CaptureStatus?
    var staleRouteCleanup: RouteCleanupStatus?

    struct CaptureStatus: Codable, Sendable {
        var activeInterfaces: [String]
        var allEthernetInterfaces: [String]
        var wifiInterface: String?
        var errors: [String]
    }

    struct RouteCleanupStatus: Codable, Equatable, Sendable {
        var removedCount: Int
        var gateway: String
        var date: Date
    }

    struct BroadRouteStatus: Codable, Sendable {
        var ipv4Present: Int
        var ipv4Total: Int
        var ipv6Present: Int
        var ipv6Total: Int
    }

    var splitTunnelState: SplitTunnelState {
        if !zscalerRunning { return .inactive }
        if broadRoutesPresent.ipv4Present == 0 && broadRoutesPresent.ipv6Present == 0 {
            return .active
        }
        return .partial
    }
}

enum SplitTunnelState: String, Codable, Sendable {
    case active
    case partial
    case inactive
    case unknown
}

struct RouteEntry: Codable, Sendable, Identifiable {
    var id: String { destination }
    let destination: String
    let gateway: String?
    let interfaceName: String?
    let isIPv6: Bool
    let routeType: RouteType

    enum RouteType: String, Codable, Sendable {
        case custom
        case bypass
        case broad
    }
}
