import XCTest

final class HelperStatusCacheTests: XCTestCase {
    func testReturnsLatestSnapshotAndCoalescesRefreshes() {
        let cache = HelperStatusCache()
        let first = cache.snapshotAndBeginRefresh()
        XCTAssertTrue(first.shouldRefresh)
        XCTAssertFalse(first.snapshot.zscalerRunning)

        XCTAssertFalse(cache.snapshotAndBeginRefresh().shouldRefresh)

        cache.finishRefresh(LiveHelperStatusRefresh(
            zscalerRunning: .success(true),
            zscalerInterface: .success("utun4"),
            broadRoutes: .success((ipv4: 0, ipv6: 0)),
            networkSignature: .success("192.168.0.1|en0|192.168.0.10")
        ))

        let refreshed = cache.snapshotAndBeginRefresh()
        XCTAssertTrue(refreshed.shouldRefresh)
        XCTAssertTrue(refreshed.snapshot.zscalerRunning)
        XCTAssertEqual(refreshed.snapshot.zscalerInterface, "utun4")
    }

    func testFailedProbesPreserveLastGoodFields() {
        let cache = HelperStatusCache()
        _ = cache.snapshotAndBeginRefresh()
        cache.finishRefresh(LiveHelperStatusRefresh(
            zscalerRunning: .success(true),
            zscalerInterface: .success("utun4"),
            broadRoutes: .success((ipv4: 2, ipv6: 1)),
            networkSignature: .success("gateway|en0|address")
        ))

        _ = cache.snapshotAndBeginRefresh()
        cache.finishRefresh(LiveHelperStatusRefresh(
            zscalerRunning: .failure,
            zscalerInterface: .success(nil),
            broadRoutes: .failure,
            networkSignature: .failure
        ))

        let snapshot = cache.snapshotAndBeginRefresh().snapshot
        XCTAssertTrue(snapshot.zscalerRunning)
        XCTAssertNil(snapshot.zscalerInterface)
        XCTAssertEqual(snapshot.broadIPv4, 2)
        XCTAssertEqual(snapshot.broadIPv6, 1)
        XCTAssertEqual(snapshot.networkSignature, "gateway|en0|address")
    }
}
