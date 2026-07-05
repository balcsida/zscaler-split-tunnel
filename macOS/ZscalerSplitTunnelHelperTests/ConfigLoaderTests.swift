import XCTest

final class ConfigLoaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-loader-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testResolvedIPv6AnswersBecomeHostRoutes() throws {
        let confURL = tempDir.appendingPathComponent("bypass.conf")
        try "example.com\n".write(to: confURL, atomically: true, encoding: .utf8)

        let resolver = DNSResolver(
            cacheURL: tempDir.appendingPathComponent("domain-cache.txt"),
            queryIPs: { _ in ["140.82.121.4", "2606:50c0:8000::154"] },
            now: { 1_000_000 }
        )
        let loader = ConfigLoader(
            dnsResolver: resolver,
            remoteFetcher: RemoteRouteFetcher(cacheURL: tempDir.appendingPathComponent("remote-cache.txt"))
        )

        let routes = loader.loadBypassRoutes(defaultFile: nil, userFile: confURL)

        XCTAssertEqual(Set(routes), ["140.82.121.4/32", "2606:50c0:8000::154/128"])
    }
}
