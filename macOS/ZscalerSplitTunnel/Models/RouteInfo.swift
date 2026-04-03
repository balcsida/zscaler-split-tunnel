import Foundation

struct RouteInfo: Identifiable, Sendable {
    let id: String
    let destination: String
    let source: String
    let configFile: String
    let resolvedIPs: [String]
    let isActive: Bool
    let routeType: RouteEntry.RouteType
}
