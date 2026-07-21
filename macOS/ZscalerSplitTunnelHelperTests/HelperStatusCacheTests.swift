import XCTest

final class HelperStatusCacheTests: XCTestCase {
    func testReturnsLatestSnapshotAndCoalescesRefreshes() {
        let cache = HelperStatusCache()
        let first = cache.snapshotAndBeginRefresh()
        XCTAssertTrue(first.shouldRefresh)
        XCTAssertFalse(first.snapshot.zscalerRunning)

        XCTAssertFalse(cache.snapshotAndBeginRefresh().shouldRefresh)

        cache.finishRefresh(LiveHelperStatus(
            zscalerRunning: true,
            zscalerInterface: "utun4",
            broadIPv4: 0,
            broadIPv6: 0,
            networkSignature: "192.168.0.1|en0|192.168.0.10"
        ))

        let refreshed = cache.snapshotAndBeginRefresh()
        XCTAssertTrue(refreshed.shouldRefresh)
        XCTAssertTrue(refreshed.snapshot.zscalerRunning)
        XCTAssertEqual(refreshed.snapshot.zscalerInterface, "utun4")
    }
}
