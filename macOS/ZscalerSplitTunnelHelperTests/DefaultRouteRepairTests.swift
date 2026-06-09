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

    func testParsesIPv6DefaultRoutersFromNDPOutput() {
        let routers = IPv6DefaultRouteRepair.parseDefaultRouters("""
        fe80::962a:6fff:feca:9069%en0 if=en0, flags=T, pref=high, expire=28m42s
        fe80::%utun0 if=utun0, flags=IST, pref=medium, expire=Never
        fe80::c0d0:7d06:4e5c:8446%en0 if=en0, flags=, pref=medium, expire=1h57m4s
        """)

        XCTAssertEqual(routers, [
            IPv6DefaultRouteRepair.Router(gateway: "fe80::962a:6fff:feca:9069%en0", interface: "en0"),
            IPv6DefaultRouteRepair.Router(gateway: "fe80::%utun0", interface: "utun0"),
            IPv6DefaultRouteRepair.Router(gateway: "fe80::c0d0:7d06:4e5c:8446%en0", interface: "en0")
        ])
    }

    func testRepairsMissingIPv6DefaultUsingFirstNonTunnelRouter() {
        var addedGateways: [String] = []
        var defaultRoute: IPv6DefaultRouteRepair.DefaultRoute?

        let result = IPv6DefaultRouteRepair.restoreIfMissing(
            getDefaultRoute: { defaultRoute },
            defaultRouters: {
                [
                    IPv6DefaultRouteRepair.Router(gateway: "fe80::%utun0", interface: "utun0"),
                    IPv6DefaultRouteRepair.Router(gateway: "fe80::962a:6fff:feca:9069%en0", interface: "en0")
                ]
            },
            addDefaultRoute: { gateway in
                addedGateways.append(gateway)
                defaultRoute = IPv6DefaultRouteRepair.DefaultRoute(gateway: gateway, interface: "en0")
                return .success
            }
        )

        XCTAssertEqual(result, .repaired(gateway: "fe80::962a:6fff:feca:9069%en0", interface: "en0"))
        XCTAssertEqual(addedGateways, ["fe80::962a:6fff:feca:9069%en0"])
    }

    func testFailsIPv6RepairWhenRouteAddDoesNotCreateUsableDefault() {
        let result = IPv6DefaultRouteRepair.restoreIfMissing(
            getDefaultRoute: { nil },
            defaultRouters: {
                [
                    IPv6DefaultRouteRepair.Router(gateway: "fe80::962a:6fff:feca:9069%en0", interface: "en0")
                ]
            },
            addDefaultRoute: { _ in .alreadyExists }
        )

        XCTAssertEqual(result, .failed(errors: ["en0: route add did not restore IPv6 default"]))
    }

    func testLeavesUsableIPv6DefaultRouteAlone() {
        let result = IPv6DefaultRouteRepair.restoreIfMissing(
            getDefaultRoute: {
                IPv6DefaultRouteRepair.DefaultRoute(gateway: "fe80::962a:6fff:feca:9069%en0", interface: "en0")
            },
            defaultRouters: {
                XCTFail("NDP routers should not be queried when default route is already usable")
                return []
            },
            addDefaultRoute: { _ in
                XCTFail("route add should not run when default route is already usable")
                return .failure("unexpected add")
            }
        )

        XCTAssertEqual(result, .defaultPresent)
    }

    func testRouteResetFlushesStaleHostRoutesForCurrentGateway() {
        var flushedGateways: [String] = []

        let removed = RouteReset.flushStaleGatewayHostRoutesIfPossible(
            getDefaultGateway: { "192.168.101.1" },
            flushStaleRoutes: { gateway in
                flushedGateways.append(gateway)
                return 12
            }
        )

        XCTAssertEqual(removed, 12)
        XCTAssertEqual(flushedGateways, ["192.168.101.1"])
    }

    func testRouteResetSkipsStaleHostRouteFlushWithoutUsableGateway() {
        var flushedGateways: [String] = []

        let removed = RouteReset.flushStaleGatewayHostRoutesIfPossible(
            getDefaultGateway: { "link#22" },
            flushStaleRoutes: { gateway in
                flushedGateways.append(gateway)
                return 12
            }
        )

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(flushedGateways, [])
    }
}

final class RouteEngineBypassRouteTests: XCTestCase {
    func testReplacesBypassRouteWhenDestinationExistsViaWrongGateway() {
        var operations: [String] = []

        let result = RouteEngine.ensureBypassRoute(
            destination: "140.82.121.5/32",
            gateway: "192.168.101.1",
            isIPv6: false,
            expectedRouteExists: { _, _, _ in false },
            anyRouteExists: { _, _ in true },
            addRoute: { _, _, _ in
                operations.append("add")
                return true
            },
            replaceRoute: { _, _, _ in
                operations.append("replace")
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(operations, ["replace"])
    }

    func testSkipsBypassRouteWhenCurrentGatewayAlreadyMatches() {
        var operations: [String] = []

        let result = RouteEngine.ensureBypassRoute(
            destination: "140.82.121.6/32",
            gateway: "192.168.101.1",
            isIPv6: false,
            expectedRouteExists: { _, _, _ in true },
            anyRouteExists: { _, _ in
                XCTFail("Any-route lookup should not run when expected route exists")
                return false
            },
            addRoute: { _, _, _ in
                operations.append("add")
                return true
            },
            replaceRoute: { _, _, _ in
                operations.append("replace")
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(operations, [])
    }

    func testAddsBypassRouteWhenDestinationDoesNotExist() {
        var operations: [String] = []

        let result = RouteEngine.ensureBypassRoute(
            destination: "140.82.121.6/32",
            gateway: "192.168.101.1",
            isIPv6: false,
            expectedRouteExists: { _, _, _ in false },
            anyRouteExists: { _, _ in false },
            addRoute: { _, _, _ in
                operations.append("add")
                return true
            },
            replaceRoute: { _, _, _ in
                operations.append("replace")
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(operations, ["add"])
    }

    func testFlushesWrongGatewayDirectHostRoutes() {
        let netstat = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.101.1      UGScg                 en0
        3.7.35/25          192.168.0.1        UGSc                  en0
        10.48/16           100.64.0.1         UGSc                utun4
        104.18.24.23/32    192.168.101.1      UGSc                  en0
        140.82.121.5/32    192.168.0.1        UGSc                  en0
        142.250.203.138/32 192.168.0.1        UGSc                  en0
        185.199.108.133/32 link#14            UHLWI                 en0
        """
        var deletedHosts: [String] = []

        let flushed = RouteEngine.flushStaleGatewayHostRoutes(
            expectedGateway: "192.168.101.1",
            netstatOutput: { netstat },
            deleteHostRoute: { host in
                deletedHosts.append(host)
                return true
            }
        )

        XCTAssertEqual(flushed, 2)
        XCTAssertEqual(deletedHosts, ["140.82.121.5", "142.250.203.138"])
    }
}
