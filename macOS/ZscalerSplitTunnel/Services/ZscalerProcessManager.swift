import Foundation
import Observation

@Observable
@MainActor
final class ZscalerProcessManager {
    var isRunning: Bool = false
    var detectedInterface: String?

    private var pollingTask: Task<Void, Never>?

    func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(AppConstants.statusPollInterval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll() async {
        let running = await Task.detached(priority: .utility) {
            Self.isZscalerRunning()
        }.value
        let iface = running ? await Task.detached(priority: .utility) {
            Self.detectZscalerInterface()
        }.value : nil
        isRunning = running
        detectedInterface = iface
    }

    private nonisolated static func isZscalerRunning() -> Bool {
        for name in AppConstants.zscalerProcessNames {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return true }
            } catch {
                continue
            }
        }
        return false
    }

    private nonisolated static func detectZscalerInterface() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", AppConstants.zscalerProbeAddress]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed
                    .replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
