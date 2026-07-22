import XCTest

final class DNSFlushTests: XCTestCase {
    func testUsesBoundedShellRunnerForBothCommands() {
        var invocations: [(path: String, arguments: [String], timeout: TimeInterval)] = []

        DNSFlush.flush { path, arguments, timeout in
            invocations.append((path, arguments, timeout))
            return 0
        }

        XCTAssertEqual(invocations.map(\.path), ["/usr/bin/dscacheutil", "/usr/bin/killall"])
        XCTAssertEqual(invocations.map(\.arguments), [["-flushcache"], ["-HUP", "mDNSResponder"]])
        XCTAssertEqual(invocations.map(\.timeout), [10, 10])
    }
}
