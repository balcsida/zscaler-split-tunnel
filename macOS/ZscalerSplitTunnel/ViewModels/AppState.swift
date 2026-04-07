import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class AppState {
    var helperStatus: HelperStatus?
    var isHelperInstalled: Bool = false
    var splitTunnelState: SplitTunnelState = .unknown
    var errorMessage: String?
    var isLoading: Bool = false
    let deviceFieldPreferences = DeviceFieldPreferences()

    let helperConnection = HelperConnection()
    let configService = ConfigService()

    private var pollingTask: Task<Void, Never>?

    init() {
        // Reflect persisted SMAppService registration state immediately so the UI is correct before
        // the first successful XPC round-trip.
        let svcStatus = SMAppService.daemon(plistName: "\(AppConstants.helperBundleID).plist").status
        isHelperInstalled = svcStatus == .enabled || svcStatus == .requiresApproval
        startStatusPolling()
    }

    func installHelper() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            let service = SMAppService.daemon(plistName: "\(AppConstants.helperBundleID).plist")
            do {
                // Unregister first to force macOS to pick up the new binary
                if service.status == .enabled {
                    try await service.unregister()
                    await helperConnection.resetConnection()
                    // Wait for launchd to fully tear down the daemon
                    try await Task.sleep(for: .seconds(2))
                }
                try service.register()
                isHelperInstalled = true
                errorMessage = nil
            } catch {
                errorMessage = "Helper install failed: \(error.localizedDescription)"
                isHelperInstalled = service.status == .enabled
            }
            isLoading = false
        }
    }

    func startMonitoring() {
        Task {
            do {
                isLoading = true
                try await helperConnection.startMonitoring(interval: AppConstants.defaultMonitorInterval)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func stopMonitoring() {
        Task {
            do {
                isLoading = true
                try await helperConnection.stopMonitoring()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func refreshNow() {
        Task {
            do {
                isLoading = true
                try await helperConnection.triggerRefresh()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func flushDNS() {
        Task {
            do {
                try await helperConnection.flushDNSCache()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startZscaler() {
        Task {
            do {
                isLoading = true
                try await helperConnection.startZscaler(consoleUser: NSUserName())
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func killZscaler() {
        Task {
            do {
                isLoading = true
                try await helperConnection.killZscaler(consoleUser: NSUserName())
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func startStatusPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchStatus()
                try? await Task.sleep(for: .seconds(AppConstants.statusPollInterval))
            }
        }
    }

    func stopStatusPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func fetchStatus() async {
        do {
            let status = try await helperConnection.getStatus()
            helperStatus = status
            splitTunnelState = status.splitTunnelState
            isHelperInstalled = true
            errorMessage = nil
        } catch {
            helperStatus = nil
            splitTunnelState = .unknown
            await helperConnection.resetConnection()
            let svcStatus = SMAppService.daemon(plistName: "\(AppConstants.helperBundleID).plist").status
            switch svcStatus {
            case .notRegistered, .notFound:
                isHelperInstalled = false
                errorMessage = "Helper not installed"
            case .requiresApproval:
                isHelperInstalled = true
                errorMessage = "Approve helper in System Settings → General → Login Items"
            case .enabled:
                isHelperInstalled = true
                errorMessage = "Helper not responding"
            @unknown default:
                break
            }
        }
    }
}
