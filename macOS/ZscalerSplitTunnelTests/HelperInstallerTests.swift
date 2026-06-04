import Foundation
import XCTest

final class HelperInstallerTests: XCTestCase {
    func testLaunchDaemonPlistAssociatesHelperWithMainAppBundle() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("ZscalerSplitTunnelHelper/Launchd.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let associatedBundleIDs = try XCTUnwrap(plist["AssociatedBundleIdentifiers"] as? [String])

        XCTAssertTrue(associatedBundleIDs.contains(AppConstants.appBundleID))
    }

    func testLaunchDaemonPlistUsesSMAppServiceHelperExecutablePath() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("ZscalerSplitTunnelHelper/Launchd.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            plist["BundleProgram"] as? String,
            "Contents/MacOS/\(AppConstants.helperBundleID)"
        )
    }

    func testAppTargetCopiesHelperToLaunchDaemonBundleProgramPath() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectFile = projectRoot.appendingPathComponent("ZscalerSplitTunnel.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)

        XCTAssertTrue(
            project.contains("Contents/MacOS/com.zscaler-split-tunnel.helper"),
            "The app target must copy the helper to the BundleProgram path."
        )
        XCTAssertFalse(
            project.contains("Contents/Library/LaunchServices/com.zscaler-split-tunnel.helper"),
            "SMAppService should launch the helper from Contents/MacOS, matching Apple's daemon packaging guidance."
        )

        let generatorFile = projectRoot.appendingPathComponent("project.yml")
        let generator = try String(contentsOf: generatorFile, encoding: .utf8)
        XCTAssertTrue(
            generator.contains("Contents/MacOS/com.zscaler-split-tunnel.helper"),
            "The generated Xcode project and project.yml must agree on the helper path."
        )
        XCTAssertFalse(
            generator.contains("Contents/Library/LaunchServices/com.zscaler-split-tunnel.helper"),
            "Regenerating the Xcode project must not restore the old helper path."
        )
    }

    func testReinstallWaitsForOldRegistrationToDisappearBeforeRegistering() async throws {
        let service = FakeHelperService(statuses: [.enabled, .enabled, .notRegistered, .enabled])
        let sleeps = SleepRecorder()
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

        XCTAssertEqual(service.events, [.status, .unregister, .status, .sleep, .status, .register, .status])
        XCTAssertEqual(sleeps.values, [.milliseconds(250)])
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
        let service = FakeHelperService(statuses: [.notRegistered, .enabled])
        let installer = HelperInstaller(service: service, sleep: { _ in XCTFail("Unexpected sleep") })

        try await installer.reinstall()

        XCTAssertEqual(service.events, [.status, .register, .status])
    }

    func testReinstallFailsWhenRegistrationDoesNotBecomeActive() async {
        let service = FakeHelperService(statuses: [.notRegistered, .notRegistered])
        let installer = HelperInstaller(service: service, sleep: { _ in XCTFail("Unexpected sleep") })

        do {
            try await installer.reinstall()
            XCTFail("Expected reinstall to fail when registration remains inactive")
        } catch HelperInstallerError.registrationDidNotBecomeActive(let status) {
            XCTAssertEqual(status, .notRegistered)
            XCTAssertEqual(HelperInstallerError.registrationDidNotBecomeActive(status).errorDescription, HelperInstallMessages.loginItemsApproval)
            XCTAssertEqual(service.events, [.status, .register, .status])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private(set) var values: [Duration] = []

    func append(_ duration: Duration) {
        values.append(duration)
    }
}

private final class FakeHelperService: HelperServiceRegistering, @unchecked Sendable {
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
