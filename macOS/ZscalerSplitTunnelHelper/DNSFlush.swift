import Foundation
import os

enum DNSFlush {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "DNSFlush")
    private static let recoveryTimeout: TimeInterval = 10

    @discardableResult
    static func flush(
        runSilent: (String, [String], TimeInterval) -> Int32 = {
            ShellRunner.runSilent($0, arguments: $1, timeout: $2)
        }
    ) -> Bool {
        let dscacheExit = runSilent("/usr/bin/dscacheutil", ["-flushcache"], recoveryTimeout)
        if dscacheExit != 0 {
            logger.error("dscacheutil DNS flush failed with exit code \(dscacheExit)")
        }

        let killallExit = runSilent("/usr/bin/killall", ["-HUP", "mDNSResponder"], recoveryTimeout)
        if killallExit != 0 {
            logger.error("mDNSResponder DNS flush failed with exit code \(killallExit)")
        }

        if dscacheExit == 0, killallExit == 0 {
            logger.info("Flushed macOS system DNS cache")
            return true
        }
        return false
    }
}
