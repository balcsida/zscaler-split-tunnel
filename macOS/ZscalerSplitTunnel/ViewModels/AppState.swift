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
    private var pendingMonitorStart = false
    /// While set (to a future date), transient `getStatus` failures are suppressed —
    /// used right after a helper reinstall, during which launchd is still booting the
    /// new daemon and the first few XPC round-trips are expected to fail.
    private var suppressHelperErrorsUntil: Date?

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
                // Unregister whenever BTM has any record of the helper, not just
                // when it's `.enabled`. After a rebuild, the binary's SHA256 no
                // longer matches what BTM cached; if we skip unregister and only
                // call register() on a `.requiresApproval` (toggled-off) entry,
                // BTM keeps the stale SHA and launchd refuses to spawn the new
                // binary with EX_CONFIG. Forcing unregister + sleep + register
                // makes BTM record the new SHA.
                if service.status == .enabled || service.status == .requiresApproval {
                    try? await service.unregister()
                    await helperConnection.resetConnection()
                    // Wait for launchd to fully tear down and BTM to drop the entry.
                    try await Task.sleep(for: .seconds(3))
                }
                try service.register()
                // Drop any existing XPC connection so the next poll opens a fresh one
                // against the daemon launchd is about to bring up.
                await helperConnection.resetConnection()
                // Suppress transient "not responding" errors while launchd boots the daemon.
                suppressHelperErrorsUntil = Date().addingTimeInterval(10)
                isHelperInstalled = true

                // If macOS still wants user approval, open Login Items so the user
                // can flip the toggle on. register() succeeds silently in that
                // case — without this hint the user sees "nothing happens".
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    errorMessage = "Approve Zscaler Split Tunnel in System Settings → Login Items → Allow in the Background, then click Reinstall Helper again."
                } else {
                    errorMessage = nil
                }
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
            isLoading = true
            errorMessage = nil
            // Helper-side killZscaler does stop-monitor + kill + RouteReset atomically,
            // which takes several seconds. Suppress the poll's auto-restart of monitoring
            // while it runs — otherwise the poll sees isMonitoring=false mid-reset and
            // kicks off startMonitoring, racing the route flush.
            pendingMonitorStart = true
            defer { pendingMonitorStart = false }
            do {
                try await helperConnection.killZscaler(consoleUser: NSUserName())
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Full connectivity-recovery sequence: stop Zscaler, stop monitoring, then flush
    /// routes and bounce active `en*` interfaces. Networking drops briefly.
    func recoverConnectivity() {
        // killZscaler now does stop-monitor + kill + RouteReset on the helper side.
        killZscaler()
    }

    /// Invokes the helper's full route reset (flush routing table, bounce DHCP).
    /// Briefly drops all connectivity before the monitor re-applies routes.
    func resetRoutes() {
        Task {
            isLoading = true
            errorMessage = nil
            pendingMonitorStart = true
            defer { pendingMonitorStart = false }
            do {
                _ = try await helperConnection.resetRoutes()
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
            suppressHelperErrorsUntil = nil

            // Auto-start monitoring only when Zscaler is actually running. Otherwise the
            // poll would resurrect monitoring immediately after the user kills Zscaler,
            // and the monitor would re-install bypass /32s through the default gateway —
            // undoing the RouteReset the helper just performed.
            if !status.isMonitoring && !pendingMonitorStart && status.zscalerRunning {
                pendingMonitorStart = true
                do {
                    try await helperConnection.startMonitoring(interval: AppConstants.defaultMonitorInterval)
                } catch {
                    errorMessage = "Auto-start monitoring failed: \(error.localizedDescription)"
                }
                pendingMonitorStart = false
            }
        } catch {
            helperStatus = nil
            splitTunnelState = .unknown
            await helperConnection.resetConnection()
            let svcStatus = SMAppService.daemon(plistName: "\(AppConstants.helperBundleID).plist").status
            let inGrace = suppressHelperErrorsUntil.map { Date() < $0 } ?? false
            switch svcStatus {
            case .notRegistered, .notFound:
                isHelperInstalled = false
                errorMessage = inGrace ? nil : "Helper not installed"
            case .requiresApproval:
                isHelperInstalled = true
                errorMessage = "Approve helper in System Settings → General → Login Items"
            case .enabled:
                isHelperInstalled = true
                errorMessage = inGrace ? nil : "Helper not responding"
            @unknown default:
                break
            }
        }
    }
}
