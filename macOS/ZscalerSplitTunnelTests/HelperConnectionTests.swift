import XCTest

final class HelperConnectionTests: XCTestCase {
    func testDNSFlushTimeoutCoversBothRecoveryCommands() {
        XCTAssertEqual(HelperConnection.dnsFlushTimeout, 25)
    }
}
