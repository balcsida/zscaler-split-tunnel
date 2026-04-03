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
}
