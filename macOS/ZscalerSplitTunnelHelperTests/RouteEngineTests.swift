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

    func testReturnsNilWithoutIPv6DefaultGateway() {
        XCTAssertNil(RouteEngine.parseIPv6DefaultGateway(routeGetOutput: """
           route to: default
        destination: default
          interface: en0
        """))
    }
}
