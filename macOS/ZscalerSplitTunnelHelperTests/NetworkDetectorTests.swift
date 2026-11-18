import XCTest

final class NetworkDetectorTests: XCTestCase {
    private let home = "192.168.1.1:en0:192.168.1.20"
    private let tunnel = "100.64.0.1:utun4:100.64.0.2"

    /// Replays signature changes the way MonitorLoop does and returns which ones flushed.
    private func flushes(startingAt start: String, through signatures: [String]) -> [Bool] {
        var lastPhysical: String? = NetworkDetector.isTunnelSignature(start) ? nil : start
        return signatures.map { signature in
            defer { if !NetworkDetector.isTunnelSignature(signature) { lastPhysical = signature } }
            return NetworkDetector.shouldFlushDNS(lastPhysicalSignature: lastPhysical, current: signature)
        }
    }

    func testTunnelFlipDoesNotFlush() {
        XCTAssertEqual(flushes(startingAt: home, through: [tunnel, home]), [false, false])
        XCTAssertEqual(flushes(startingAt: home, through: ["none:ipsec0:none", home, "none:ppp0:none", home]),
                       [false, false, false, false])
    }

    func testPhysicalChangeFlushes() {
        XCTAssertEqual(flushes(startingAt: home, through: [
            "192.168.1.254:en0:192.168.1.20", // gateway
            "192.168.1.254:en0:192.168.1.21", // IP
            "192.168.1.254:en7:192.168.1.21", // interface (e.g. dock Ethernet)
        ]), [true, true, true])
    }

    func testPhysicalChangeBehindTunnelFlushesOnReturn() {
        XCTAssertEqual(flushes(startingAt: home, through: [tunnel, "10.0.0.1:en0:10.0.0.5"]), [false, true])
    }

    func testManualRefreshDoesNotFlush() {
        XCTAssertFalse(NetworkDetector.shouldFlushDNS(lastPhysicalSignature: home, current: nil))
    }

    func testFirstSignatureDoesNotFlush() {
        XCTAssertFalse(NetworkDetector.shouldFlushDNS(lastPhysicalSignature: nil, current: home))
    }
}
