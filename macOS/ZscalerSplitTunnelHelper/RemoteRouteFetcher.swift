import Foundation
import os

extension ProxySettings {
    static func sessionConfiguration(configURL: URL) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let endpoint = endpoint(configURL: configURL) { host, port in
            ShellRunner.runStatus(
                "/usr/bin/nc",
                arguments: ["-z", "-w1", host, String(port)]
            ).exitCode == 0
        }
        guard let endpoint, let host = endpoint.host else {
            return configuration
        }

        let port = endpoint.port ?? 80
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port
        ]
        return configuration
    }
}

final class RemoteRouteFetcher: Sendable {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "RemoteRouteFetcher")

    private let cacheURL: URL
    private let proxyConfigURL: URL

    init(
        cacheURL: URL = ConfigPaths.remoteRouteCache,
        proxyConfigURL: URL = ConfigPaths.consoleUserProxyConfig
    ) {
        self.cacheURL = cacheURL
        self.proxyConfigURL = proxyConfigURL
    }

    func fetch(_ urlString: String) -> [String] {
        guard urlString.hasPrefix("https://") else {
            Self.logger.error("Refusing to fetch remote routes over insecure URL: \(urlString)")
            return []
        }

        let cacheKey = "url:\(urlString)"
        let now = Int(Date().timeIntervalSince1970)

        // Check cache
        let cachedRoutes = readCacheEntry(key: cacheKey, maxAge: AppConstants.remoteCacheExpireSeconds, now: now)
        if let cachedRoutes, !cachedRoutes.isEmpty {
            Self.logger.info("Using cached remote routes for \(urlString)")
            return cachedRoutes
        }

        // Fetch via URLSession (synchronous for helper)
        guard let url = URL(string: urlString) else { return cachedRoutes ?? [] }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var fetchedData: Data?

        let session = URLSession(configuration: ProxySettings.sessionConfiguration(configURL: proxyConfigURL))
        let task = session.dataTask(with: url) { data, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                fetchedData = data
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        session.invalidateAndCancel()

        guard let data = fetchedData, let content = String(data: data, encoding: .utf8) else {
            Self.logger.warning("Failed to fetch remote routes from \(urlString)")
            return cachedRoutes ?? []
        }

        let routes = parseRoutes(from: content)

        if routes.isEmpty {
            Self.logger.warning("No valid routes found in remote source: \(urlString)")
            return cachedRoutes ?? []
        }

        writeCacheEntry(key: cacheKey, timestamp: now, values: routes)
        return routes
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Parsing

    private func parseRoutes(from content: String) -> [String] {
        var routes = Set<String>()

        // Match CIDR notation: IP/prefix
        let cidrPattern = #"\b(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}\b"#
        if let regex = try? NSRegularExpression(pattern: cidrPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range, in: content) {
                    let token = String(content[range])
                    if IPValidator.isValidIPCIDR(token) {
                        routes.insert(token)
                    }
                }
            }
        }

        // Match bare IPv4 addresses (add /32)
        let ipv4Pattern = #"\b(\d{1,3}\.){3}\d{1,3}\b"#
        if let regex = try? NSRegularExpression(pattern: ipv4Pattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range, in: content) {
                    let token = String(content[range])
                    if !token.contains("/") && IPValidator.isValidIPCIDR(token) {
                        routes.insert("\(token)/32")
                    }
                }
            }
        }

        // Match IPv6 CIDR
        let ipv6CidrPattern = #"\b[0-9a-fA-F:]+/\d{1,3}\b"#
        if let regex = try? NSRegularExpression(pattern: ipv6CidrPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range, in: content) {
                    let token = String(content[range])
                    if token.contains(":") && IPValidator.isValidIPCIDR(token) {
                        routes.insert(token)
                    }
                }
            }
        }

        return routes.sorted()
    }

    // MARK: - Cache

    private func readCacheEntry(key: String, maxAge: Int, now: Int) -> [String]? {
        guard let data = try? String(contentsOf: cacheURL, encoding: .utf8) else { return nil }
        for line in data.components(separatedBy: "\n") {
            guard line.hasPrefix("\(key)=") else { continue }
            let rest = String(line.dropFirst(key.count + 1))
            guard let sepIndex = rest.firstIndex(of: "|") else { continue }
            let tsStr = rest[rest.startIndex..<sepIndex]
            let valuesStr = rest[rest.index(after: sepIndex)...]
            guard let ts = Int(tsStr) else { continue }
            if now - ts < maxAge {
                return String(valuesStr).split(separator: " ").map(String.init).filter { !$0.isEmpty }
            }
        }
        return nil
    }

    private func writeCacheEntry(key: String, timestamp: Int, values: [String]) {
        var lines: [String] = []
        if let existing = try? String(contentsOf: cacheURL, encoding: .utf8) {
            for line in existing.components(separatedBy: "\n") {
                if !line.hasPrefix("\(key)=") && !line.isEmpty {
                    lines.append(line)
                }
            }
        }
        lines.append("\(key)=\(timestamp)|\(values.joined(separator: " "))")
        try? lines.joined(separator: "\n").write(to: cacheURL, atomically: true, encoding: .utf8)
    }
}
