import XCTest

final class ProxySettingsTests: XCTestCase {
    func testProcessProbeStopsAtDeadline() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 5"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let start = Date()

        XCTAssertFalse(ProxySettings.runProbe(process, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testUsesConfiguredProxyOnlyWhenReachable() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-settings-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: configURL) }
        try "# Local proxy\nno_proxy=localhost,api.example.test\nhttp://proxy.example:8080\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ProxySettings.endpoint(configURL: configURL) { host, port in
                host == "proxy.example" && port == 8080
            },
            URL(string: "http://proxy.example:8080")
        )
        XCTAssertNil(ProxySettings.endpoint(configURL: configURL) { _, _ in false })
    }

    func testWritesShellEnvironmentWithConfiguredNoProxy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-environment-\(UUID().uuidString)")
        let configURL = directory.appendingPathComponent("proxy.conf")
        let environmentURL = directory.appendingPathComponent("proxy.env")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "http://proxy.example:8080\nno_proxy=localhost,api.example.test'quoted\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        ProxySettings.refreshEnvironment(
            configURL: configURL,
            environmentURL: environmentURL,
            isReachable: { _, _ in true }
        )

        XCTAssertEqual(
            try String(contentsOf: environmentURL, encoding: .utf8),
            """
            export HTTP_PROXY='http://proxy.example:8080'
            export HTTPS_PROXY='http://proxy.example:8080'
            export http_proxy='http://proxy.example:8080'
            export https_proxy='http://proxy.example:8080'
            export NO_PROXY='localhost,api.example.test'\\''quoted'
            export no_proxy='localhost,api.example.test'\\''quoted'

            """
        )
    }

    func testRemovesShellEnvironmentWhenProxyIsUnreachable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-environment-\(UUID().uuidString)")
        let configURL = directory.appendingPathComponent("proxy.conf")
        let environmentURL = directory.appendingPathComponent("proxy.env")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "http://proxy.example:8080\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        try "stale\n".write(to: environmentURL, atomically: true, encoding: .utf8)

        ProxySettings.refreshEnvironment(
            configURL: configURL,
            environmentURL: environmentURL,
            isReachable: { _, _ in false }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: environmentURL.path))
    }

    func testUsesLocalhostNoProxyByDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-environment-\(UUID().uuidString)")
        let configURL = directory.appendingPathComponent("proxy.conf")
        let environmentURL = directory.appendingPathComponent("proxy.env")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "http://proxy.example:8080\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        ProxySettings.refreshEnvironment(
            configURL: configURL,
            environmentURL: environmentURL,
            isReachable: { _, _ in true }
        )

        let contents = try String(contentsOf: environmentURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("export NO_PROXY='localhost,127.0.0.1'"))
        XCTAssertTrue(contents.contains("export no_proxy='localhost,127.0.0.1'"))
    }
}
