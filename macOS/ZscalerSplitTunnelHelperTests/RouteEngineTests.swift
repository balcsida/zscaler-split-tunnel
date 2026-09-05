import XCTest

final class RouteEngineTests: XCTestCase {
    func testParsesScopedLinkLocalIPv6DefaultGateway() {
        let gateway = RouteEngine.parseIPv6DefaultGateway(routeGetOutput: """
           route to: default
        destination: default
               mask: default
            gateway: fe80::962a:6fff:feca:9067%en0
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """)

        XCTAssertEqual(gateway, "fe80::962a:6fff:feca:9067%en0")
    }

    func testRejectsIPv6DefaultGatewayOnTunnelInterface() {
        let gateway = RouteEngine.parseIPv6DefaultGateway(routeGetOutput: """
           route to: default
        destination: default
            gateway: fe80::1%utun8
          interface: utun8
        """)

        XCTAssertNil(gateway)
    }

    func testMatchesInstalledIPv6PrefixRouteByBaseAddress() {
        // route(8) reports prefix routes by their base address, so an
        // installed 2a0a:a440::/29 must count as present — otherwise the
        // monitor deletes and re-adds it every cycle.
        XCTAssertTrue(RouteEngine.routeGetOutputIndicatesInstalledRoute(
            destination: "2a0a:a440::/29",
            expectedGateway: "fe80::962a:6fff:feca:9067%en0",
            isIPv6: true,
            output: """
               route to: 2a0a:a440::
            destination: 2a0a:a440::
                   mask: ffff:fff8::
                gateway: fe80::962a:6fff:feca:9067%en0
              interface: en0
            """
        ))
    }

    func testRejectsIPv6PrefixRouteWithWrongGateway() {
        XCTAssertFalse(RouteEngine.routeGetOutputIndicatesInstalledRoute(
            destination: "2a0a:a440::/29",
            expectedGateway: "fe80::962a:6fff:feca:9067%en0",
            isIPv6: true,
            output: """
            destination: 2a0a:a440::
                gateway: fe80::1%utun8
              interface: utun8
            """
        ))
    }

    func testRejectsDefaultRouteFallbackAsInstalledRoute() {
        XCTAssertFalse(RouteEngine.routeGetOutputIndicatesInstalledRoute(
            destination: "2a0a:a440::/29",
            expectedGateway: nil,
            isIPv6: true,
            output: """
            destination: default
                gateway: fe80::962a:6fff:feca:9067%en0
              interface: en0
            """
        ))
    }

    func testReturnsNilWithoutIPv6DefaultGateway() {
        XCTAssertNil(RouteEngine.parseIPv6DefaultGateway(routeGetOutput: """
           route to: default
        destination: default
          interface: en0
        """))
    }
}
