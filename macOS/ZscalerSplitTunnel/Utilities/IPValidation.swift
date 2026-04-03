import Foundation

enum IPValidation {
    static func isValidIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = UInt16(part), octet <= 255 else { return false }
            return true
        }
    }

    static func isValidIPv6(_ string: String) -> Bool {
        // Strip CIDR suffix if present for pure address check
        let addr = string.contains("/") ? String(string.prefix(while: { $0 != "/" })) : string
        // Quick structural check: must contain at least one colon
        guard addr.contains(":") else { return false }
        // Use inet_pton for authoritative validation
        var addr6 = in6_addr()
        return inet_pton(AF_INET6, addr, &addr6) == 1
    }

    static func isValidCIDR(_ string: String) -> Bool {
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }

        let address = String(parts[0])

        // IPv4 CIDR
        if isValidIPv4(address) {
            return prefix >= 0 && prefix <= 32
        }

        // IPv6 CIDR
        if isValidIPv6(address) {
            return prefix >= 0 && prefix <= 128
        }

        return false
    }

    static func isValidDomain(_ string: String) -> Bool {
        let pattern = #"^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"#
        return string.range(of: pattern, options: .regularExpression) != nil
    }

    static func isValidURL(_ string: String) -> Bool {
        return string.hasPrefix("http://") || string.hasPrefix("https://")
    }
}
