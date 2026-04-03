import Foundation
import os

enum ZscalerServiceManager {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "ZscalerServiceManager")

    static func start(consoleUser: String) {
        logger.info("Starting Zscaler application and services")

        let consoleUID = getUID(for: consoleUser)
        let consoleDomain = consoleUID.map { "gui/\($0)" }

        // Bootstrap LaunchDaemons
        let daemons = findPlists(in: "/Library/LaunchDaemons", matching: "zscaler")
        for daemon in daemons {
            if ShellRunner.runSilent("/bin/launchctl", arguments: ["bootstrap", "system", daemon]) == 0 {
                logger.info("Bootstrapped LaunchDaemon: \(daemon)")
            } else {
                ShellRunner.runSilent("/bin/launchctl", arguments: ["load", daemon])
            }
        }

        // Bootstrap LaunchAgents
        if let domain = consoleDomain {
            let agents = findPlists(in: "/Library/LaunchAgents", matching: "zscaler")
            for agent in agents {
                if ShellRunner.runSilent("/bin/launchctl", arguments: ["bootstrap", domain, agent]) == 0 {
                    logger.info("Bootstrapped LaunchAgent: \(agent)")
                } else {
                    ShellRunner.runSilent("/bin/launchctl", arguments: ["load", agent])
                }
            }
        }

        // Open Zscaler.app if not running
        let (pgrepOutput, _) = ShellRunner.run("/usr/bin/pgrep", arguments: ["-x", "Zscaler"])
        if pgrepOutput?.isEmpty ?? true {
            ShellRunner.runSilent("/usr/bin/open", arguments: ["-a", AppConstants.zscalerAppPath, "--hide"])
            logger.info("Opened Zscaler.app")
        } else {
            logger.info("Zscaler is already running")
        }
    }

    static func kill(consoleUser: String) {
        logger.info("Killing Zscaler application and services")

        let consoleUID = getUID(for: consoleUser)
        let consoleDomain = consoleUID.map { "gui/\($0)" }

        // Bootout LaunchAgents
        if let domain = consoleDomain {
            let agents = findPlists(in: "/Library/LaunchAgents", matching: "zscaler")
            for agent in agents {
                if ShellRunner.runSilent("/bin/launchctl", arguments: ["bootout", domain, agent]) != 0 {
                    ShellRunner.runSilent("/bin/launchctl", arguments: ["unload", agent])
                }
            }
        }

        // Bootout LaunchDaemons
        let daemons = findPlists(in: "/Library/LaunchDaemons", matching: "zscaler")
        for daemon in daemons {
            if ShellRunner.runSilent("/bin/launchctl", arguments: ["bootout", "system", daemon]) != 0 {
                ShellRunner.runSilent("/bin/launchctl", arguments: ["unload", daemon])
            }
        }

        // Kill processes
        for process in AppConstants.zscalerProcessNames {
            ShellRunner.runSilent("/usr/bin/pkill", arguments: ["-x", process])
        }

        logger.info("Zscaler services stopped")
    }

    static func isRunning() -> Bool {
        let (output, exitCode) = ShellRunner.run("/usr/bin/pgrep", arguments: ["-x", "Zscaler"])
        return exitCode == 0 && !(output?.isEmpty ?? true)
    }

    // MARK: - Private

    private static func getUID(for user: String) -> String? {
        let (output, exitCode) = ShellRunner.run("/usr/bin/id", arguments: ["-u", user])
        guard exitCode == 0, let output, !output.isEmpty else { return nil }
        return output
    }

    private static func findPlists(in directory: String, matching pattern: String) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return contents
            .filter { $0.lowercased().contains(pattern) && $0.hasSuffix(".plist") }
            .map { "\(directory)/\($0)" }
    }
}
