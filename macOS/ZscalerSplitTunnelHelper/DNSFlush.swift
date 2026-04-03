import Foundation
import os

enum DNSFlush {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "DNSFlush")

    static func flush() {
        let dscacheutil = Process()
        dscacheutil.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        dscacheutil.arguments = ["-flushcache"]
        dscacheutil.standardOutput = FileHandle.nullDevice
        dscacheutil.standardError = FileHandle.nullDevice
        do {
            try dscacheutil.run()
            dscacheutil.waitUntilExit()
        } catch {
            logger.error("Failed to run dscacheutil: \(error.localizedDescription)")
        }

        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["-HUP", "mDNSResponder"]
        killall.standardOutput = FileHandle.nullDevice
        killall.standardError = FileHandle.nullDevice
        do {
            try killall.run()
            killall.waitUntilExit()
        } catch {
            logger.error("Failed to run killall mDNSResponder: \(error.localizedDescription)")
        }

        logger.info("Flushed macOS system DNS cache")
    }
}
