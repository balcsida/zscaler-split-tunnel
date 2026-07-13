import Darwin
import Foundation

enum ShellRunner {
    static let timeoutExitCode: Int32 = 124
    private static let defaultTimeout: TimeInterval = 10
    private static let terminationGrace: TimeInterval = 1

    private struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    @discardableResult
    static func run(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = defaultTimeout
    ) -> (output: String?, exitCode: Int32) {
        let result = execute(
            executablePath,
            arguments: arguments,
            captureStdout: true,
            captureStderr: false,
            timeout: timeout
        )
        return (result.exitCode == -1 ? nil : result.stdout, result.exitCode)
    }

    @discardableResult
    static func runSilent(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = defaultTimeout
    ) -> Int32 {
        execute(
            executablePath,
            arguments: arguments,
            captureStdout: false,
            captureStderr: false,
            timeout: timeout
        ).exitCode
    }

    /// Runs a process capturing both stdout and stderr separately, so callers can log
    /// the real error message when a command fails.
    static func runCapturingStderr(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = defaultTimeout
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        let result = execute(
            executablePath,
            arguments: arguments,
            captureStdout: true,
            captureStderr: true,
            timeout: timeout
        )
        return (result.stdout, result.stderr, result.exitCode)
    }

    private static func execute(
        _ executablePath: String,
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = captureStdout ? Pipe() : nil
        let errPipe = captureStderr ? Pipe() : nil
        process.standardOutput = outPipe ?? FileHandle.nullDevice
        process.standardError = errPipe ?? FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: "launch failed: \(error.localizedDescription)", exitCode: -1)
        }

        let reads = DispatchGroup()
        let stdout = DataBox()
        let stderr = DataBox()
        for (pipe, box) in [(outPipe, stdout), (errPipe, stderr)] {
            guard let pipe else { continue }
            reads.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                reads.leave()
            }
        }

        let timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                terminated.wait()
            }
        }
        reads.wait()

        return Result(
            stdout: string(from: stdout.data),
            stderr: string(from: stderr.data),
            exitCode: timedOut ? timeoutExitCode : process.terminationStatus
        )
    }

    private static func string(from data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
