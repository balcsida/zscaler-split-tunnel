import Foundation

enum ReconciliationSchedule {
    static func shouldRunFullRefresh(
        lastFullRefresh: Date?,
        now: Date,
        nextCheckIn: TimeInterval = 0,
        forced: Bool = false
    ) -> Bool {
        forced || lastFullRefresh.map {
            let elapsed = now.timeIntervalSince($0)
            let interval = TimeInterval(AppConstants.cacheExpireSeconds)
            return elapsed >= interval || elapsed + nextCheckIn > interval
        } ?? true
    }
}
