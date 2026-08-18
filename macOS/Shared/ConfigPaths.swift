import Foundation
import SystemConfiguration

enum ConfigPaths {
    // MARK: - Current process user paths (used by the app)

    static let userConfigDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zscaler-split-tunnel")
    }()

    static let routesConfig = userConfigDir.appendingPathComponent("routes.conf")
    static let bypassConfig = userConfigDir.appendingPathComponent("bypass.conf")
    static let configMtime = userConfigDir.appendingPathComponent("routes.mtime")
    static let domainCache = userConfigDir.appendingPathComponent("domain-cache.txt")
    static let remoteRouteCache = userConfigDir.appendingPathComponent("remote-route-cache.txt")
    static let legacyRoutesConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zscaler-split-tunnel.conf")
    }()

    static let legacyBypassConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zscaler-bypass.conf")
    }()

    // MARK: - Console user paths (used by the helper daemon running as root)

    /// Resolves the config directory for the currently logged-in console user.
    /// When the helper runs as root, `homeDirectoryForCurrentUser` returns `/var/root/`.
    /// This method detects the actual GUI user and resolves their home directory instead.
    static var consoleUserConfigDir: URL {
        if let homeDir = consoleUserHomeDirectory() {
            return homeDir.appendingPathComponent(".config/zscaler-split-tunnel")
        }
        return userConfigDir
    }

    static var consoleUserRoutesConfig: URL {
        consoleUserConfigDir.appendingPathComponent("routes.conf")
    }

    static var consoleUserBypassConfig: URL {
        consoleUserConfigDir.appendingPathComponent("bypass.conf")
    }

    static var consoleUserDomainCache: URL {
        consoleUserConfigDir.appendingPathComponent("domain-cache.txt")
    }

    static var consoleUserRemoteRouteCache: URL {
        consoleUserConfigDir.appendingPathComponent("remote-route-cache.txt")
    }

    static var consoleUserProxyConfig: URL {
        consoleUserConfigDir.appendingPathComponent("proxy.conf")
    }

    static var consoleUserOfficeModeConfig: URL {
        consoleUserConfigDir.appendingPathComponent("office-mode.json")
    }

    static var officeModeConfig: URL {
        userConfigDir.appendingPathComponent("office-mode.json")
    }

    static var consoleUserLegacyRoutesConfig: URL? {
        guard let homeDir = consoleUserHomeDirectory() else { return nil }
        return homeDir.appendingPathComponent(".config/zscaler-split-tunnel.conf")
    }

    static var consoleUserLegacyBypassConfig: URL? {
        guard let homeDir = consoleUserHomeDirectory() else { return nil }
        return homeDir.appendingPathComponent(".config/zscaler-bypass.conf")
    }

    // MARK: - Bundle defaults

    static var defaultRoutesConfig: URL? {
        Bundle.main.url(forResource: "zscaler-split-tunnel", withExtension: "conf", subdirectory: "config")
    }

    static var defaultBypassConfig: URL? {
        Bundle.main.url(forResource: "zscaler-bypass", withExtension: "conf", subdirectory: "config")
    }

    // MARK: - Utilities

    static func ensureUserConfigDir() throws {
        try FileManager.default.createDirectory(at: userConfigDir, withIntermediateDirectories: true)
    }

    static func ensureConsoleUserConfigDir() throws {
        try FileManager.default.createDirectory(at: consoleUserConfigDir, withIntermediateDirectories: true)
    }

    /// Returns the home directory of the currently logged-in console user.
    private static func consoleUserHomeDirectory() -> URL? {
        guard let username = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?,
              !username.isEmpty,
              username != "loginwindow" else {
            return nil
        }
        return NSHomeDirectoryForUser(username).map { URL(fileURLWithPath: $0) }
    }
}
