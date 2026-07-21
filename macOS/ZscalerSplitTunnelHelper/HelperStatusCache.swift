import Foundation

struct LiveHelperStatus: Sendable {
    var zscalerRunning = false
    var zscalerInterface: String?
    var broadIPv4 = 0
    var broadIPv6 = 0
    var networkSignature: String?
}

final class HelperStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = LiveHelperStatus()
    private var refreshInProgress = false

    func snapshotAndBeginRefresh() -> (snapshot: LiveHelperStatus, shouldRefresh: Bool) {
        lock.withLock {
            let shouldRefresh = !refreshInProgress
            refreshInProgress = true
            return (snapshot, shouldRefresh)
        }
    }

    func finishRefresh(_ snapshot: LiveHelperStatus) {
        lock.withLock {
            self.snapshot = snapshot
            refreshInProgress = false
        }
    }
}
