import Foundation

struct LiveHelperStatus: Sendable {
    var zscalerRunning = false
    var zscalerInterface: String?
    var broadIPv4 = 0
    var broadIPv6 = 0
    var networkSignature: String?
}

enum StatusProbe<Value> {
    case success(Value)
    case failure
}

struct LiveHelperStatusRefresh {
    let zscalerRunning: StatusProbe<Bool>
    let zscalerInterface: StatusProbe<String?>
    let broadRoutes: StatusProbe<(ipv4: Int, ipv6: Int)>
    let networkSignature: StatusProbe<String?>
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

    func finishRefresh(_ refresh: LiveHelperStatusRefresh) {
        lock.withLock {
            if case .success(let value) = refresh.zscalerRunning {
                snapshot.zscalerRunning = value
            }
            if case .success(let value) = refresh.zscalerInterface {
                snapshot.zscalerInterface = value
            }
            if case .success(let value) = refresh.broadRoutes {
                snapshot.broadIPv4 = value.ipv4
                snapshot.broadIPv6 = value.ipv6
            }
            if case .success(let value) = refresh.networkSignature {
                snapshot.networkSignature = value
            }
            refreshInProgress = false
        }
    }
}
