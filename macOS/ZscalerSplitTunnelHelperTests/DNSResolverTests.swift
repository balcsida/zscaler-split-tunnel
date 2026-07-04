import XCTest

final class DNSResolverTests: XCTestCase {
    private var cacheURL: URL!

    override func setUp() {
        super.setUp()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dns-cache-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
        super.tearDown()
    }

    func testAccumulatesRotatingAnswersAcrossRefreshes() {
        nonisolated(unsafe) var clock = 1_000_000
        nonisolated(unsafe) var answer = ["140.82.121.4"]
        let resolver = DNSResolver(cacheURL: cacheURL, queryIPs: { _ in answer }, now: { clock })

        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4"])

        clock += AppConstants.cacheExpireSeconds + 1
        answer = ["140.82.121.5"]
        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4", "140.82.121.5"])

        clock += AppConstants.cacheExpireSeconds + 1
        answer = ["140.82.121.6"]
        XCTAssertEqual(
            resolver.resolve("github.com"),
            ["140.82.121.4", "140.82.121.5", "140.82.121.6"]
        )
    }

    func testDropsIPsNotSeenWithinRetentionWindow() {
        nonisolated(unsafe) var clock = 1_000_000
        nonisolated(unsafe) var answer = ["140.82.121.4"]
        let resolver = DNSResolver(cacheURL: cacheURL, queryIPs: { _ in answer }, now: { clock })

        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4"])

        clock += AppConstants.dnsRetentionSeconds + 1
        answer = ["140.82.121.5"]
        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.5"])
    }

    func testReturnsCachedIPsWithoutRequeryWhileFresh() {
        nonisolated(unsafe) var clock = 1_000_000
        nonisolated(unsafe) var queryCount = 0
        let resolver = DNSResolver(
            cacheURL: cacheURL,
            queryIPs: { _ in
                queryCount += 1
                return ["140.82.121.4"]
            },
            now: { clock }
        )

        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4"])
        clock += AppConstants.cacheExpireSeconds - 1
        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4"])
        XCTAssertEqual(queryCount, 1)
    }

    func testKeepsAccumulatedIPsWhenResolutionFails() {
        nonisolated(unsafe) var clock = 1_000_000
        nonisolated(unsafe) var answer = ["140.82.121.4"]
        nonisolated(unsafe) var queryCount = 0
        let resolver = DNSResolver(
            cacheURL: cacheURL,
            queryIPs: { _ in
                queryCount += 1
                return answer
            },
            now: { clock }
        )

        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4"])

        clock += AppConstants.cacheExpireSeconds + 1
        answer = []
        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4"])
        XCTAssertEqual(queryCount, 2)

        // The failure is negative-cached: no re-query inside the backoff window,
        // and the accumulated IPs are still served.
        clock += AppConstants.negativeCacheExpireSeconds - 1
        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.4"])
        XCTAssertEqual(queryCount, 2)
    }

    func testReadsLegacyCacheFormat() {
        let clock = 1_000_000
        try? "domain:github.com=\(clock - 10) 140.82.121.6 185.199.108.133"
            .write(to: cacheURL, atomically: true, encoding: .utf8)
        nonisolated(unsafe) var queryCount = 0
        let resolver = DNSResolver(
            cacheURL: cacheURL,
            queryIPs: { _ in
                queryCount += 1
                return []
            },
            now: { clock }
        )

        XCTAssertEqual(resolver.resolve("github.com"), ["140.82.121.6", "185.199.108.133"])
        XCTAssertEqual(queryCount, 0)
    }
}
