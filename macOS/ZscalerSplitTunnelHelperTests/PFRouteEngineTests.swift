import XCTest

final class PFRouteEngineTests: XCTestCase {
    private func rules(_ ruleset: String) -> [String] {
        ruleset.split(separator: "\n").map(String.init).filter { $0.hasPrefix("nat ") || $0.hasPrefix("pass ") }
    }

    func testTranslatesBypassTrafficOnTunnelBeforeRouting() {
        let ruleset = PFRouteEngine.previewRuleset(
            physInterface: "en0",
            physGatewayV4: "192.0.2.1",
            physGatewayV6: "fe80::1%en0",
            zscalerInterface: "utun4"
        )

        XCTAssertEqual(rules(ruleset), [
            "nat on utun4 inet from any to <bypass_v4> -> (en0)",
            "nat on utun4 inet6 from any to <bypass_v6> -> (en0)",
            "nat on en0 inet from any to <forced_v4> -> (utun4)",
            "nat on en0 inet6 from any to <forced_v6> -> (utun4)",
            "pass out quick on utun4 route-to (en0 192.0.2.1) inet from any to <bypass_v4>",
            "pass out quick on utun4 route-to (en0 fe80::1%en0) inet6 from any to <bypass_v6>",
            "pass out quick on en0 route-to utun4 inet from any to <forced_v4>",
            "pass out quick on en0 route-to utun4 inet6 from any to <forced_v6>",
        ])
    }

    func testOmitsRulesWithMissingOrUnsafeInput() {
        let unsafe = [
            ("en0; pass all", "192.0.2.1", "utun4"),
            ("en0", "192.0.2.1) pass all", "utun4"),
            ("en0", "2001:db8::1", "utun4"), // wrong family for v4 gateway
            ("en0", "192.0.2.0/24", "utun4"),
            ("en0", "", "utun4"),
        ]
        for (phys, gw, zs) in unsafe {
            XCTAssertFalse(
                rules(PFRouteEngine.previewRuleset(physInterface: phys, physGatewayV4: gw, physGatewayV6: nil, zscalerInterface: zs))
                    .contains { $0.contains("bypass") },
                "\(phys) \(gw) \(zs)"
            )
        }
        XCTAssertEqual(rules(PFRouteEngine.previewRuleset(
            physInterface: "en0", physGatewayV4: "192.0.2.1", physGatewayV6: nil, zscalerInterface: nil
        )), [])
    }
}
