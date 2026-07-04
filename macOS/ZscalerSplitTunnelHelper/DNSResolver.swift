import Foundation
import os

final class DNSResolver: Sendable {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "DNSResolver")

    private let cacheURL: URL
    private let queryIPs: @Sendable (String) -> [String]
    private let now: @Sendable () -> Int

    init(
        cacheURL: URL = ConfigPaths.domainCache,
        queryIPs: @escaping @Sendable (String) -> [String] = DNSResolver.digQuery,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
    ) {
        self.cacheURL = cacheURL
        self.queryIPs = queryIPs
        self.now = now
    }

    func resolve(_ domain: String) -> [String] {
        let cacheKey = "domain:\(domain)"
        let negativeCacheKey = "negative-domain:\(domain)"
        let timestamp = now()

        let retained = readAccumulatedEntry(key: cacheKey, now: timestamp)
        if let retained, timestamp - retained.refreshedAt < AppConstants.cacheExpireSeconds {
            return retained.ips.keys.sorted()
        }
        if readCacheEntry(key: negativeCacheKey, maxAge: AppConstants.negativeCacheExpireSeconds, now: timestamp) != nil {
            Self.logger.debug("Skipping recently failed domain resolution: \(domain)")
            return retained?.ips.keys.sorted() ?? []
        }

        let fresh = queryIPs(domain)
        guard !fresh.isEmpty else {
            Self.logger.warning("Failed to resolve domain: \(domain)")
            writeCacheEntry(key: negativeCacheKey, timestamp: timestamp, values: ["-"])
            return retained?.ips.keys.sorted() ?? []
        }

        // Merge instead of replace: DNS answers for rotating domains (e.g.
        // github.com cycles through several A records) only ever contain one
        // sibling per query, so previously seen IPs must stay covered until
        // they age past the retention window.
        var merged = retained?.ips ?? [:]
        for ip in fresh {
            merged[ip] = timestamp
        }
        writeAccumulatedEntry(key: cacheKey, refreshedAt: timestamp, ips: merged)
        return merged.keys.sorted()
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Resolution

    static func digQuery(_ domain: String) -> [String] {
        var ips = Set<String>()
        let (aOutput, _) = ShellRunner.run("/usr/bin/dig", arguments: ["+short", domain, "A"])
        if let aOutput {
            for line in aOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if isValidIPv4(trimmed) {
                    ips.insert(trimmed)
                }
            }
        }

        let (aaaaOutput, _) = ShellRunner.run("/usr/bin/dig", arguments: ["+short", domain, "AAAA"])
        if let aaaaOutput {
            for line in aaaaOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if isValidIPv6(trimmed) {
                    ips.insert(trimmed)
                }
            }
        }

        return ips.sorted()
    }

    // MARK: - Cache

    private struct AccumulatedEntry {
        var refreshedAt: Int
        var ips: [String: Int]
    }

    /// Reads a `domain:` entry, dropping IPs not seen within the retention
    /// window. Tokens are `ip@lastSeen`; bare `ip` tokens (legacy format)
    /// inherit the entry's refresh timestamp as their last-seen time.
    private func readAccumulatedEntry(key: String, now: Int) -> AccumulatedEntry? {
        guard let data = try? String(contentsOf: cacheURL, encoding: .utf8) else { return nil }
        for line in data.components(separatedBy: "\n") {
            guard line.hasPrefix("\(key)=") else { continue }
            let rest = String(line.dropFirst(key.count + 1))
            let tokens = rest.split(separator: " ")
            guard let first = tokens.first, let refreshedAt = Int(first) else { continue }
            var ips: [String: Int] = [:]
            for token in tokens.dropFirst() {
                let pieces = token.split(separator: "@", maxSplits: 1)
                guard let ip = pieces.first.map(String.init), !ip.isEmpty else { continue }
                let lastSeen = pieces.count == 2 ? Int(pieces[1]) ?? refreshedAt : refreshedAt
                if now - lastSeen < AppConstants.dnsRetentionSeconds {
                    ips[ip] = lastSeen
                }
            }
            guard !ips.isEmpty else { return nil }
            return AccumulatedEntry(refreshedAt: refreshedAt, ips: ips)
        }
        return nil
    }

    private func writeAccumulatedEntry(key: String, refreshedAt: Int, ips: [String: Int]) {
        let values = ips.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value)" }
        writeCacheEntry(key: key, timestamp: refreshedAt, values: values)
    }

    private func readCacheEntry(key: String, maxAge: Int, now: Int) -> [String]? {
        guard let data = try? String(contentsOf: cacheURL, encoding: .utf8) else { return nil }
        for line in data.components(separatedBy: "\n") {
            guard line.hasPrefix("\(key)=") else { continue }
            let rest = String(line.dropFirst(key.count + 1))
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count >= 2, let ts = Int(parts[0]) else { continue }
            if now - ts < maxAge {
                return String(parts[1]).split(separator: " ").map(String.init)
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
        lines.append("\(key)=\(timestamp) \(values.joined(separator: " "))")
        try? lines.joined(separator: "\n").write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Validation

    private static func isValidIPv4(_ str: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        guard str.range(of: pattern, options: .regularExpression) != nil else { return false }
        return str.split(separator: ".").allSatisfy { Int($0).map { $0 <= 255 } ?? false }
    }

    private static func isValidIPv6(_ str: String) -> Bool {
        let pattern = #"^[0-9a-fA-F:]+$"#
        return str.contains(":") && str.range(of: pattern, options: .regularExpression) != nil
    }
}
