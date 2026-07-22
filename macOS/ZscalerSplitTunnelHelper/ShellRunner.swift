import Darwin
import Foundation

enum ShellRunner {
    static let timeoutExitCode: Int32 = 124
    static let statusTimeout: TimeInterval = 2
    private static let defaultTimeout: TimeInterval = 10
    private static let terminationGrace: TimeInterval = 1
    private static let killConfirmationGrace: TimeInterval = 0.1

    private struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let stdoutIsValidUTF8: Bool
    }

    private final class PipeCapture: @unchecked Sendable {
        let pipe = Pipe()

        private let queue = DispatchQueue(label: "ShellRunner.PipeCapture", qos: .userInitiated)
        private let lock = NSLock()
        private let completed = DispatchSemaphore(value: 0)
        private var data = Data()
        private var isCompleted = false
        private var source: DispatchSourceRead?

        func start() {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                finish()
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drain(maxBytes: max(Int(source.data), 1))
            }
            source.setCancelHandler { [weak self] in self?.finish() }
            self.source = source
            source.resume()
        }

        func wait(until deadline: DispatchTime) -> Bool {
            completed.wait(timeout: deadline) == .success
        }

        func cancel() {
            queue.sync {
                drain(maxBytes: Int(source?.data ?? 0))
                source?.cancel()
            }
            try? pipe.fileHandleForReading.close()
            finish()
        }

        func snapshot() -> Data {
            queue.sync { data }
        }

        private func drain(maxBytes: Int) {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 4096)
            var remaining = maxBytes
            while remaining > 0 {
                let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    remaining -= count
                } else if count == 0 {
                    source?.cancel()
                    return
                } else {
                    return
                }
            }
        }

        private func finish() {
            lock.lock()
            guard !isCompleted else {
                lock.unlock()
                return
            }
            isCompleted = true
            lock.unlock()
            completed.signal()
        }
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
        return (result.exitCode == -1 || !result.stdoutIsValidUTF8 ? nil : result.stdout, result.exitCode)
    }

    static func runStatus(
        _ executablePath: String,
        arguments: [String] = []
    ) -> (output: String?, exitCode: Int32) {
        run(executablePath, arguments: arguments, timeout: statusTimeout)
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

        let stdout = captureStdout ? PipeCapture() : nil
        let stderr = captureStderr ? PipeCapture() : nil
        process.standardOutput = stdout?.pipe ?? FileHandle.nullDevice
        process.standardError = stderr?.pipe ?? FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let captures = [stdout, stderr].compactMap { $0 }
        captures.forEach { $0.start() }

        do {
            try process.run()
        } catch {
            captures.forEach { $0.cancel() }
            return Result(
                stdout: "",
                stderr: "launch failed: \(error.localizedDescription)",
                exitCode: -1,
                stdoutIsValidUTF8: true
            )
        }

        let timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            captures.forEach { $0.cancel() }
            process.terminate()
            if terminated.wait(timeout: .now() + terminationGrace) == .timedOut {
                if kill(process.processIdentifier, SIGKILL) == 0 {
                    _ = terminated.wait(timeout: .now() + killConfirmationGrace)
                }
            }
        } else {
            let drainDeadline = DispatchTime.now() + terminationGrace
            captures.filter { !$0.wait(until: drainDeadline) }.forEach { $0.cancel() }
        }

        let stdoutData = stdout?.snapshot() ?? Data()
        let stdoutString = String(data: stdoutData, encoding: .utf8)

        return Result(
            stdout: trim(stdoutString) ?? "",
            stderr: trim(String(data: stderr?.snapshot() ?? Data(), encoding: .utf8)) ?? "",
            exitCode: timedOut ? timeoutExitCode : process.terminationStatus,
            stdoutIsValidUTF8: stdoutString != nil
        )
    }

    private static func trim(_ string: String?) -> String? {
        string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
