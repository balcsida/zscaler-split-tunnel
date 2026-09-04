import Foundation
import Network

@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let onPathChange: @Sendable () -> Void

    init(onPathChange: @escaping @Sendable () -> Void) {
        self.onPathChange = onPathChange
    }

    func start() {
        let onPathChange = onPathChange
        monitor.pathUpdateHandler = { _ in
            onPathChange()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
