import Foundation

struct BroadRoute: Identifiable, Sendable {
    let id: String
    let route: String
    let isIPv6: Bool
    var isPresent: Bool

    static var all: [BroadRoute] {
        let ipv4 = AppConstants.ipv4BroadRoutes.map { route in
            BroadRoute(id: "v4:\(route)", route: route, isIPv6: false, isPresent: false)
        }
        let ipv6 = AppConstants.ipv6BroadRoutes.map { route in
            BroadRoute(id: "v6:\(route)", route: route, isIPv6: true, isPresent: false)
        }
        return ipv4 + ipv6
    }
}
