import XCTest

final class DefaultRouteRepairTests: XCTestCase {
    func testParsesDHCPServiceInfoWithRouter() {
        let info = DefaultRouteRepair.parseServiceInfo("""
        DHCP Configuration
        IP address: 172.20.10.8
        Subnet mask: 255.255.255.240
        Router: 172.20.10.1
        Client ID:
        IPv6: Automatic
        IPv6 IP address: none
        IPv6 Router: none
        """)

        XCTAssertEqual(info, DefaultRouteRepair.ServiceInfo(
            router: "172.20.10.1",
            usesDHCP: true
        ))
    }

    func testOnlyIPv4GatewaysAreUsableDefaults() {
        XCTAssertTrue(DefaultRouteRepair.isUsableIPv4Gateway("172.20.10.1"))
        XCTAssertFalse(DefaultRouteRepair.isUsableIPv4Gateway("link#31"))
        XCTAssertFalse(DefaultRouteRepair.isUsableIPv4Gateway(nil))
    }

    func testRepairsMissingDefaultRouteUsingServiceRouterBeforeDHCPRenewal() {
        var gateway: String?
        var changedGateways: [String] = []
        var dhcpRenewals: [String] = []

        let result = DefaultRouteRepair.restoreIfMissing(
            getDefaultGateway: { gateway },
            activeServices: {
                [DefaultRouteRepair.NetworkService(service: "iPhone USB", device: "en12")]
            },
            serviceInfo: { _ in
                DefaultRouteRepair.ServiceInfo(router: "172.20.10.1", usesDHCP: true)
            },
            changeDefaultRoute: { candidate in
                changedGateways.append(candidate)
                gateway = candidate
                return .success
            },
            addDefaultRoute: { _ in
                XCTFail("route add should not be used after a successful route change")
                return .failure("unexpected add")
            },
            renewDHCP: { service in
                dhcpRenewals.append(service.service)
                return true
            }
        )

        XCTAssertEqual(result, .repairedByRouteChange(service: "iPhone USB", gateway: "172.20.10.1"))
        XCTAssertEqual(changedGateways, ["172.20.10.1"])
        XCTAssertEqual(dhcpRenewals, [])
    }

    func testTreatsLinkLayerDefaultAsMissingAndRepairsFromServiceRouter() {
        var gateway: String? = "link#31"
        var changedGateways: [String] = []

        let result = DefaultRouteRepair.restoreIfMissing(
            getDefaultGateway: { gateway },
            activeServices: {
                [DefaultRouteRepair.NetworkService(service: "iPhone USB", device: "en12")]
            },
            serviceInfo: { _ in
                DefaultRouteRepair.ServiceInfo(router: "172.20.10.1", usesDHCP: true)
            },
            changeDefaultRoute: { candidate in
                changedGateways.append(candidate)
                gateway = candidate
                return .success
            },
            addDefaultRoute: { _ in
                XCTFail("route add should not be used after a successful route change")
                return .failure("unexpected add")
            },
            renewDHCP: { _ in
                XCTFail("DHCP should not be renewed after a successful route change")
                return true
            }
        )

        XCTAssertEqual(result, .repairedByRouteChange(service: "iPhone USB", gateway: "172.20.10.1"))
        XCTAssertEqual(changedGateways, ["172.20.10.1"])
    }

    func testDoesNotRenewDHCPForManualServiceWhenRouterRepairFails() {
        var addGateways: [String] = []
        var dhcpRenewals: [String] = []

        let result = DefaultRouteRepair.restoreIfMissing(
            getDefaultGateway: { nil },
            activeServices: {
                [DefaultRouteRepair.NetworkService(service: "USB Ethernet", device: "en9")]
            },
            serviceInfo: { _ in
                DefaultRouteRepair.ServiceInfo(router: "192.0.2.1", usesDHCP: false)
            },
            changeDefaultRoute: { _ in .failure("route change failed") },
            addDefaultRoute: { candidate in
                addGateways.append(candidate)
                return .failure("route add failed")
            },
            renewDHCP: { service in
                dhcpRenewals.append(service.service)
                return true
            }
        )

        XCTAssertEqual(result, .failed(errors: [
            "USB Ethernet: route change failed",
            "USB Ethernet: route add failed"
        ]))
        XCTAssertEqual(addGateways, ["192.0.2.1"])
        XCTAssertEqual(dhcpRenewals, [])
    }
}
