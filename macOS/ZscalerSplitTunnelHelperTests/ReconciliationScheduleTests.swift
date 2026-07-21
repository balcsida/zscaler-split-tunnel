import XCTest

final class ReconciliationScheduleTests: XCTestCase {
    func testRunsInitiallyAndWhenForced() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ReconciliationSchedule.shouldRunFullRefresh(lastFullRefresh: nil, now: now))
        XCTAssertTrue(ReconciliationSchedule.shouldRunFullRefresh(
            lastFullRefresh: now,
            now: now,
            forced: true
        ))
    }

    func testWaitsFiveMinutesBetweenFullRefreshes() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ReconciliationSchedule.shouldRunFullRefresh(
            lastFullRefresh: last,
            now: last.addingTimeInterval(299)
        ))
        XCTAssertTrue(ReconciliationSchedule.shouldRunFullRefresh(
            lastFullRefresh: last,
            now: last.addingTimeInterval(300)
        ))
    }
}
