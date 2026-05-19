import Foundation
import os

final class DNSResolver: Sendable {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "DNSResolver")

    private let cacheURL: URL

    init(cacheURL: URL = ConfigPaths.domainCache) {
        self.cacheURL = cacheURL
    }

    func resolve(_ domain: String) -> [String] {
        let cacheKey = "domain:\(domain)"
        let negativeCacheKey = "negative-domain:\(domain)"
        let now = Int(Date().timeIntervalSince1970)

        // Check cache
        if let cached = readCacheEntry(key: cacheKey, maxAge: AppConstants.cacheExpireSeconds, now: now) {
            return cached
        }
        if readCacheEntry(key: negativeCacheKey, maxAge: AppConstants.negativeCacheExpireSeconds, now: now) != nil {
            Self.logger.debug("Skipping recently failed domain resolution: \(domain)")
            return []
        }

        // Resolve A records
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

        // Resolve AAAA records
        let (aaaaOutput, _) = ShellRunner.run("/usr/bin/dig", arguments: ["+short", domain, "AAAA"])
        if let aaaaOutput {
            for line in aaaaOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if isValidIPv6(trimmed) {
                    ips.insert(trimmed)
                }
            }
        }

        guard !ips.isEmpty else {
            Self.logger.warning("Failed to resolve domain: \(domain)")
            writeCacheEntry(key: negativeCacheKey, timestamp: now, values: ["-"])
            return []
        }

        let sorted = ips.sorted()
        writeCacheEntry(key: cacheKey, timestamp: now, values: sorted)
        return sorted
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Cache

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

    private func isValidIPv4(_ str: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        guard str.range(of: pattern, options: .regularExpression) != nil else { return false }
        return str.split(separator: ".").allSatisfy { Int($0).map { $0 <= 255 } ?? false }
    }

    private func isValidIPv6(_ str: String) -> Bool {
        let pattern = #"^[0-9a-fA-F:]+$"#
        return str.contains(":") && str.range(of: pattern, options: .regularExpression) != nil
    }
}
