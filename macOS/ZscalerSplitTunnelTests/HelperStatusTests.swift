import XCTest

final class HelperStatusTests: XCTestCase {
    private func status(
        zscalerRunning: Bool = true,
        isMonitoring: Bool = true,
        broadPresent: Int = 0,
        broadRoutesRemoved: Int? = 3
    ) -> HelperStatus {
        HelperStatus(
            isMonitoring: isMonitoring,
            monitorInterval: 30,
            zscalerRunning: zscalerRunning,
            zscalerInterface: "utun8",
            broadRoutesPresent: .init(ipv4Present: broadPresent, ipv4Total: 10, ipv6Present: 0, ipv6Total: 4),
            customRouteCount: 0,
            bypassRouteCount: 0,
            lastRefresh: nil,
            networkSignature: nil,
            version: "test",
            officeMode: .disabled,
            broadRoutesRemoved: broadRoutesRemoved
        )
    }

    func testTunnelOffWhenZscalerNeverInstalledBroadRoutes() {
        XCTAssertEqual(status(broadRoutesRemoved: 0).splitTunnelState, .tunnelOff)
    }

    func testActiveWhenBroadRoutesWereRemoved() {
        XCTAssertEqual(status(broadRoutesRemoved: 3).splitTunnelState, .active)
    }

    func testActiveWhileSweepsStillPending() {
        // nil = follow-up sweeps outstanding; do not claim "tunnel off" yet.
        XCTAssertEqual(status(broadRoutesRemoved: nil).splitTunnelState, .active)
    }

    func testTunnelOffRequiresMonitoring() {
        // Without the monitor no sweep ever ran, so a zero count proves nothing.
        XCTAssertEqual(status(isMonitoring: false, broadRoutesRemoved: 0).splitTunnelState, .active)
    }

    func testOtherStatesUnchanged() {
        XCTAssertEqual(status(zscalerRunning: false, broadRoutesRemoved: 0).splitTunnelState, .inactive)
        XCTAssertEqual(status(broadPresent: 2, broadRoutesRemoved: 0).splitTunnelState, .partial)
    }
}
