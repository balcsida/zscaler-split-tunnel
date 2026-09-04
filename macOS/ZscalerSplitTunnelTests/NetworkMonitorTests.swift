import XCTest

final class NetworkMonitorTests: XCTestCase {
    @MainActor
    func testStartReportsInitialNetworkPath() {
        let callback = DispatchSemaphore(value: 0)
        let monitor = NetworkMonitor(onPathChange: { callback.signal() })

        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(callback.wait(timeout: .now() + 2), .success)
    }
}
