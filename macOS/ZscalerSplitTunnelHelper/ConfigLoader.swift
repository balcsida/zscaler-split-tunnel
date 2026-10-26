import Foundation
import os

final class ConfigLoader: Sendable {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "ConfigLoader")

    private let dnsResolver: DNSResolver
    private let remoteFetcher: RemoteRouteFetcher

    init(dnsResolver: DNSResolver = DNSResolver(), remoteFetcher: RemoteRouteFetcher = RemoteRouteFetcher()) {
        self.dnsResolver = dnsResolver
        self.remoteFetcher = remoteFetcher
    }

    func loadRoutes(defaultFile: URL?, userFile: URL?) -> [String] {
        return loadEntries(defaultFile: defaultFile, userFile: userFile, label: "custom")
    }

    func loadBypassRoutes(defaultFile: URL?, userFile: URL?) -> [String] {
        return loadEntries(defaultFile: defaultFile, userFile: userFile, label: "bypass")
    }

    func clearCaches() {
        dnsResolver.clearCache()
        remoteFetcher.clearCache()
    }

    // MARK: - Private

    private func loadEntries(defaultFile: URL?, userFile: URL?, label: String) -> [String] {
        var sources: [URL] = []
        if let defaultFile, FileManager.default.fileExists(atPath: defaultFile.path) {
            sources.append(defaultFile)
        }
        if let userFile, FileManager.default.fileExists(atPath: userFile.path) {
            sources.append(userFile)
        } else {
            // Check legacy paths (resolve from console user's home when running as root)
            let legacyFile = label == "bypass"
                ? ConfigPaths.consoleUserLegacyBypassConfig
                : ConfigPaths.consoleUserLegacyRoutesConfig
            if let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) {
                sources.append(legacyFile)
            }
        }

        guard !sources.isEmpty else {
            Self.logger.info("No \(label) configuration found")
            return []
        }

        var routes = [String]()
        var seen = Set<String>()

        for source in sources {
            Self.logger.info("Loading \(label) configuration from \(source.path)")
            guard let content = try? String(contentsOf: source, encoding: .utf8) else { continue }

            for rawLine in content.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }

                // Handle wildcards (*.domain or .domain)
                var normalized = line
                var isWildcard = false
                if normalized.hasPrefix("*.") {
                    normalized = String(normalized.dropFirst(2))
                    isWildcard = true
                } else if normalized.hasPrefix(".") {
                    normalized = String(normalized.dropFirst(1))
                    isWildcard = true
                }

                if IPValidator.isDomain(normalized) {
                    if isWildcard {
                        Self.logger.info("Resolving \(label) wildcard: \(line) (normalized to \(normalized))")
                    } else {
                        Self.logger.info("Resolving \(label) domain: \(normalized)")
                    }
                    let ips = dnsResolver.resolve(normalized)
                    for ip in ips {
                        // Bare resolved addresses become host routes; the host
                        // prefix length is family-specific (/32 on an IPv6
                        // address would cover the provider's whole allocation).
                        let hostPrefix = IPValidator.isIPv6(ip) ? "128" : "32"
                        let candidate = ip.contains("/") ? ip : "\(ip)/\(hostPrefix)"
                        if seen.insert(candidate).inserted {
                            routes.append(candidate)
                        }
                    }
                } else if IPValidator.isURL(line) {
                    Self.logger.info("Fetching \(label) routes from remote source: \(line)")
                    let remoteRoutes = remoteFetcher.fetch(line)
                    var count = 0
                    for route in remoteRoutes {
                        guard IPValidator.isValidIPCIDR(route) else { continue }
                        if seen.insert(route).inserted {
                            routes.append(route)
                            count += 1
                        }
                    }
                    if count > 0 {
                        Self.logger.info("Loaded \(count) \(label) routes from \(line)")
                    }
                } else if IPValidator.isValidIPCIDR(line) {
                    if seen.insert(line).inserted {
                        routes.append(line)
                    }
                } else {
                    Self.logger.warning("Invalid entry in \(label) config (\(source.lastPathComponent)): \(line)")
                }
            }
        }

        Self.logger.info("Loaded \(routes.count) \(label) routes from \(sources.count) source(s)")
        return routes
    }
}
