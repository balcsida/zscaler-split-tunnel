import Foundation

enum ReconciliationSchedule {
    static func shouldRunFullRefresh(
        lastFullRefresh: Date?,
        now: Date,
        forced: Bool = false
    ) -> Bool {
        forced || lastFullRefresh.map {
            now.timeIntervalSince($0) >= TimeInterval(AppConstants.cacheExpireSeconds)
        } ?? true
    }
}
