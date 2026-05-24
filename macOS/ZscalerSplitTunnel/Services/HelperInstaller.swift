import Foundation
import ServiceManagement

enum HelperServiceStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unknown
        }
    }

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }

    var isInstalled: Bool {
        isRegistered
    }
}

enum HelperInstallerError: LocalizedError, Equatable {
    case unregisterTimedOut

    var errorDescription: String? {
        switch self {
        case .unregisterTimedOut:
            return "Timed out waiting for the old helper registration to unload. Quit Zscaler Split Tunnel and try reinstalling the helper again."
        }
    }
}

@MainActor
protocol HelperServiceRegistering: AnyObject, Sendable {
    var status: HelperServiceStatus { get }
    func register() throws
    func unregister() async throws
}

final class SMAppServiceHelperRegistration: HelperServiceRegistering, @unchecked Sendable {
    private let plistName: String

    init(plistName: String = "\(AppConstants.helperBundleID).plist") {
        self.plistName = plistName
    }

    var status: HelperServiceStatus {
        HelperServiceStatus(makeService().status)
    }

    func register() throws {
        try makeService().register()
    }

    func unregister() async throws {
        let service = makeService()
        try await service.unregister()
    }

    private func makeService() -> SMAppService {
        SMAppService.daemon(plistName: plistName)
    }
}

@MainActor
struct HelperInstaller {
    private let service: any HelperServiceRegistering
    private let pollInterval: Duration
    private let maxUnregisterWait: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        service: HelperServiceRegistering,
        pollInterval: Duration = .milliseconds(250),
        maxUnregisterWait: Duration = .seconds(10),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pollInterval = pollInterval
        self.maxUnregisterWait = maxUnregisterWait
        self.sleep = sleep
    }

    func reinstall() async throws {
        if service.status.isRegistered {
            try await service.unregister()
            try await waitForUnregistration()
        }

        try service.register()
    }

    private func waitForUnregistration() async throws {
        var waited: Duration = .zero
        while service.status.isRegistered {
            guard waited < maxUnregisterWait else {
                throw HelperInstallerError.unregisterTimedOut
            }

            try await sleep(pollInterval)
            waited += pollInterval
        }
    }
}
