import XCTest

final class DNSFlushTests: XCTestCase {
    func testUsesBoundedShellRunnerForBothCommands() {
        var invocations: [(path: String, arguments: [String], timeout: TimeInterval)] = []

        let succeeded = DNSFlush.flush { path, arguments, timeout in
            invocations.append((path, arguments, timeout))
            return 0
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(invocations.map(\.path), ["/usr/bin/dscacheutil", "/usr/bin/killall"])
        XCTAssertEqual(invocations.map(\.arguments), [["-flushcache"], ["-HUP", "mDNSResponder"]])
        XCTAssertEqual(invocations.map(\.timeout), [10, 10])
    }

    func testReportsFailureWhenEitherCommandFails() {
        for exitCodes in [[1, 0], [0, 1]] {
            var remaining = exitCodes.map(Int32.init)

            XCTAssertFalse(DNSFlush.flush { _, _, _ in remaining.removeFirst() })
        }
    }
}
