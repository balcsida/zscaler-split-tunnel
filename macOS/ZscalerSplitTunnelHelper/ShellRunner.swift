import Foundation

enum ShellRunner {
    @discardableResult
    static func run(_ executablePath: String, arguments: [String] = []) -> (output: String?, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (nil, -1)
        }

        // Read pipe data BEFORE waitUntilExit to avoid deadlock when output exceeds pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, process.terminationStatus)
    }

    @discardableResult
    static func runSilent(_ executablePath: String, arguments: [String] = []) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// Runs a process capturing both stdout and stderr separately, so callers can log
    /// the real error message when a command fails.
    static func runCapturingStderr(_ executablePath: String, arguments: [String] = [])
        -> (stdout: String, stderr: String, exitCode: Int32)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ("", "launch failed: \(error.localizedDescription)", -1)
        }

        // Drain pipes before waitUntilExit to avoid deadlocks when output exceeds buffer size.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }
}
