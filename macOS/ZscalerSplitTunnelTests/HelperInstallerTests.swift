import XCTest

@MainActor
final class HelperInstallerTests: XCTestCase {
    func testReinstallWaitsForOldRegistrationToDisappearBeforeRegistering() async throws {
        let service = FakeHelperService(statuses: [.enabled, .enabled, .notRegistered])
        var sleeps: [Duration] = []
        let installer = HelperInstaller(
            service: service,
            pollInterval: .milliseconds(250),
            maxUnregisterWait: .seconds(2),
            sleep: { duration in
                service.recordSleep()
                sleeps.append(duration)
            }
        )

        try await installer.reinstall()

        XCTAssertEqual(service.events, [.status, .unregister, .status, .sleep, .status, .register])
        XCTAssertEqual(sleeps, [.milliseconds(250)])
    }

    func testReinstallFailsWithoutRegisteringWhenOldRegistrationPersists() async {
        let service = FakeHelperService(statuses: [.enabled, .enabled, .enabled, .enabled])
        let installer = HelperInstaller(
            service: service,
            pollInterval: .milliseconds(250),
            maxUnregisterWait: .milliseconds(500),
            sleep: { _ in service.recordSleep() }
        )

        do {
            try await installer.reinstall()
            XCTFail("Expected reinstall to fail when the old registration never unloads")
        } catch HelperInstallerError.unregisterTimedOut {
            XCTAssertEqual(service.events, [.status, .unregister, .status, .sleep, .status, .sleep, .status])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInstallRegistersImmediatelyWhenNoExistingRegistrationIsPresent() async throws {
        let service = FakeHelperService(statuses: [.notRegistered])
        let installer = HelperInstaller(service: service, sleep: { _ in XCTFail("Unexpected sleep") })

        try await installer.reinstall()

        XCTAssertEqual(service.events, [.status, .register])
    }
}

@MainActor
private final class FakeHelperService: HelperServiceRegistering {
    enum Event: Equatable {
        case status
        case unregister
        case register
        case sleep
    }

    private var statuses: [HelperServiceStatus]
    private(set) var events: [Event] = []

    init(statuses: [HelperServiceStatus]) {
        self.statuses = statuses
    }

    var status: HelperServiceStatus {
        events.append(.status)
        guard statuses.count > 1 else {
            return statuses[0]
        }
        return statuses.removeFirst()
    }

    func unregister() async throws {
        events.append(.unregister)
    }

    func register() throws {
        events.append(.register)
    }

    func recordSleep() {
        events.append(.sleep)
    }
}
