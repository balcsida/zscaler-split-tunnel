import Foundation
import Network
import Observation

@Observable
@MainActor
final class NetworkMonitor {
    var isConnected: Bool = true
    var interfaceType: String = ""

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let name = Self.interfaceName(for: path)
            Task { @MainActor in
                self?.isConnected = connected
                self?.interfaceType = name
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    nonisolated private static func interfaceName(for path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if path.usesInterfaceType(.cellular) { return "Cellular" }
        if path.usesInterfaceType(.loopback) { return "Loopback" }
        return "Other"
    }
}
