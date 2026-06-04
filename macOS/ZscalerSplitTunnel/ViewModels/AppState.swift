import Foundation
import Observation
import Security
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
    private var pendingHelperInstallFailure: String?

    init() {
        // Reflect persisted SMAppService registration state immediately so the UI is correct before
        // the first successful XPC round-trip.
        let svcStatus = SMAppService.daemon(plistName: "\(AppConstants.helperBundleID).plist").status
        isHelperInstalled = svcStatus == .enabled || svcStatus == .requiresApproval
        // Populate config from disk and watch for external edits so the in-memory
        // snapshot stays current without depending on the Settings tab being opened.
        configService.load()
        configService.startWatching()
        startStatusPolling()
    }

    func installHelper() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        pendingHelperInstallFailure = nil

        Task {
            let service = SMAppServiceHelperRegistration()
            let installer = HelperInstaller(service: service)
            do {
                if let signingProblem = helperLaunchSigningProblem() {
                    errorMessage = signingProblem
                    isHelperInstalled = service.status.isInstalled
                    isLoading = false
                    return
                }

                // Unregister whenever BTM has any record of the helper, then wait
                // until ServiceManagement sees the old record disappear. After a
                // rebuild, the binary's SHA256 no longer matches what BTM cached;
                // registering too early can keep launchd pinned to the stale helper.
                if service.status.isRegistered {
                    await helperConnection.resetConnection()
                }
                try await installer.reinstall()
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
                    pendingHelperInstallFailure = HelperInstallMessages.loginItemsApproval
                    errorMessage = HelperInstallMessages.loginItemsApproval
                } else {
                    errorMessage = nil
                }
            } catch {
                if let installerError = error as? HelperInstallerError,
                   case .registrationDidNotBecomeActive = installerError {
                    pendingHelperInstallFailure = error.localizedDescription
                    SMAppService.openSystemSettingsLoginItems()
                    errorMessage = error.localizedDescription
                } else {
                    pendingHelperInstallFailure = nil
                    errorMessage = "Helper install failed: \(error.localizedDescription)"
                }
                isHelperInstalled = service.status.isInstalled
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
            pendingHelperInstallFailure = nil

            // Auto-start monitoring only when Zscaler is actually running. Otherwise the
            // poll would resurrect monitoring immediately after the user kills Zscaler,
            // and the monitor would re-install direct override /32s through the default gateway —
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
            let svcStatus = HelperServiceStatus(
                SMAppService.daemon(plistName: "\(AppConstants.helperBundleID).plist").status
            )
            let inGrace = suppressHelperErrorsUntil.map { Date() < $0 } ?? false
            switch svcStatus {
            case .notRegistered, .notFound:
                isHelperInstalled = false
                errorMessage = inGrace ? nil : (pendingHelperInstallFailure ?? "Helper not installed")
            case .requiresApproval:
                isHelperInstalled = true
                pendingHelperInstallFailure = HelperInstallMessages.loginItemsApproval
                errorMessage = HelperInstallMessages.loginItemsApproval
            case .enabled:
                isHelperInstalled = true
                errorMessage = inGrace ? nil : (helperLaunchSigningProblem() ?? "Helper not responding")
            case .unknown:
                break
            }
        }
    }

    private func helperLaunchSigningProblem() -> String? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(AppConstants.helperBundleID)

        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return "Helper executable is missing from the app bundle. Rebuild the app and reinstall the helper."
        }

        if let appIssue = codeSigningIssue(for: Bundle.main.bundleURL, componentName: "app") {
            return helperLaunchError(for: appIssue)
        }

        if let helperIssue = codeSigningIssue(for: helperURL, componentName: "helper") {
            return helperLaunchError(for: helperIssue)
        }

        return nil
    }

    private func helperLaunchError(for issue: String) -> String {
        "Helper cannot launch because the \(issue). Build the app with a valid Apple Development or Developer ID certificate, then reinstall the helper."
    }

    private func codeSigningIssue(for url: URL, componentName: String) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return "\(componentName) code signature cannot be read (\(securityErrorMessage(createStatus)))"
        }

        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        if infoStatus == errSecSuccess,
           let info = signingInfo as? [String: Any],
           let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
           flags & 0x0002 != 0 {
            return "\(componentName) is signed to run locally"
        }

        let validityStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        guard validityStatus == errSecSuccess else {
            return "\(componentName) code signature is invalid (\(securityErrorMessage(validityStatus)))"
        }

        return nil
    }

    private func securityErrorMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
