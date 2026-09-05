import XCTest

final class ZscalerInterfaceTests: XCTestCase {
    func testProbesTunnelNetworkInsteadOfShadowedHost() {
        XCTAssertEqual(ZscalerInterface.routeArguments, ["-n", "get", "-net", "100.64.0.0/16"])
    }

    func testAcceptsZscalerNetworkOnTunnel() {
        XCTAssertEqual(ZscalerInterface.parse("""
            destination: 100.64.0.0
                   mask: 255.255.0.0
              interface: utun8
            """), "utun8")
    }

    func testRejectsStaleWiFiHostRoute() {
        XCTAssertNil(ZscalerInterface.parse("""
            destination: 100.64.1.3
              interface: en0
                  flags: <UP,HOST,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF>
            """))
        XCTAssertNil(ZscalerInterface.parse("""
            destination: 100.64.0.0
                   mask: 255.255.0.0
              interface: en0
            """))
    }

    func testRejectsDefaultRoutesWhenZscalerNetworkIsMissing() {
        for interface in ["en0", "utun2"] {
            XCTAssertNil(ZscalerInterface.parse("""
                destination: default
                       mask: default
                  interface: \(interface)
                """))
        }
        XCTAssertNil(ZscalerInterface.parse(""))
    }
}
