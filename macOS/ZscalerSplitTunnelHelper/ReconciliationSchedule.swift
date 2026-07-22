import Foundation

enum ReconciliationSchedule {
    static func shouldRunFullRefresh(
        lastFullRefresh: Date?,
        now: Date,
        nextCheckIn: TimeInterval = 0,
        forced: Bool = false
    ) -> Bool {
        forced || lastFullRefresh.map {
            now.addingTimeInterval(nextCheckIn).timeIntervalSince($0)
                >= TimeInterval(AppConstants.cacheExpireSeconds)
        } ?? true
    }
}
