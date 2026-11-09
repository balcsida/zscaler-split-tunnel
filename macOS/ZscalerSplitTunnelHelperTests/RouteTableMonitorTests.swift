import XCTest

final class RouteTableMonitorTests: XCTestCase {
    private func feed(_ text: String) -> [String] {
        let parser = RouteTableMonitor.Parser()
        return text.components(separatedBy: "\n").compactMap { parser.feed($0) }
    }

    func testReportsZscalerBroadRouteAdd() {
        XCTAssertEqual(feed("""
        got message of size 152 on Mon Nov  9 12:53:10 2026
        RTM_ADD: Add Route: len 152, pid: 42689, seq 1, errno 0, flags:<UP,GATEWAY,DONE,STATIC>
        locks:  inits:
        sockaddrs: <DST,GATEWAY,NETMASK>
         1.0.0.0 100.64.0.1 255.0.0.0

        got message of size 164 on Mon Nov  9 12:53:10 2026
        RTM_ADD: Add Route: len 164, pid: 42689, seq 1, errno 0, flags:<UP,GATEWAY,DONE,STATIC>
        locks:  inits:
        sockaddrs: <DST,GATEWAY,NETMASK>
         2000:: fc00::6440:1 e000::
        """), ["1.0.0.0", "2000::"])
    }

    func testIgnoresDeletesOtherRoutesAndOwnIPv6Repair() {
        XCTAssertEqual(feed("""
        RTM_DELETE: Delete Route: len 116, pid: 9300, seq 1, errno 0, flags:<UP,GATEWAY,STATIC>
        locks:  inits:
        sockaddrs: <DST,NETMASK>
         1.0.0.0 255.0.0.0

        RTM_ADD: Add Route: len 152, pid: 2991, seq 1, errno 0, flags:<UP,GATEWAY,DONE,STATIC>
        locks:  inits:
        sockaddrs: <DST,GATEWAY,NETMASK>
         165.225.200.15 100.64.0.1 255.255.255.255

        RTM_ADD: Add Route: len 152, pid: 2991, seq 1, errno 0, flags:<UP,GATEWAY,DONE,STATIC>
        locks:  inits:
        sockaddrs: <DST,GATEWAY,NETMASK>
         :: fe80::962a:6fff:feca:9067%en0 default

        RTM_GET: Report Metrics: len 160, pid: 69464, seq 1, errno 0, flags:<UP,GATEWAY,HOST,DONE>
        sockaddrs: <DST,GATEWAY,IFP,IFA>
         1.0.0.0 100.64.0.1 index: 28 utun4 100.64.0.1
        """), [])
    }
}
