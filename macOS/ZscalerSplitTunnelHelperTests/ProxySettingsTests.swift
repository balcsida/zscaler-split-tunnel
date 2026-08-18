import XCTest

final class ProxySettingsTests: XCTestCase {
    func testUsesConfiguredProxyOnlyWhenReachable() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-settings-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: configURL) }
        try "# Local proxy\nhttp://proxy.example:8080\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ProxySettings.endpoint(configURL: configURL) { host, port in
                host == "proxy.example" && port == 8080
            },
            URL(string: "http://proxy.example:8080")
        )
        XCTAssertNil(ProxySettings.endpoint(configURL: configURL) { _, _ in false })
    }
}
