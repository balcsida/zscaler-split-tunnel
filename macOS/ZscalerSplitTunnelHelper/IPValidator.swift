import Foundation

enum IPValidator {
    static func isValidIPCIDR(_ input: String) -> Bool {
        if isValidIPv4CIDR(input) { return true }
        if isValidIPv6CIDR(input) { return true }
        return false
    }

    static func isIPv6(_ input: String) -> Bool {
        input.contains(":")
    }

    static func isDomain(_ input: String) -> Bool {
        let pattern = #"^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"#
        return input.range(of: pattern, options: .regularExpression) != nil
    }

    static func isURL(_ input: String) -> Bool {
        input.hasPrefix("https://") || input.hasPrefix("http://")
    }

    // MARK: - Private

    private static func isValidIPv4CIDR(_ input: String) -> Bool {
        let parts = input.split(separator: "/", maxSplits: 1)
        let ipPart = String(parts[0])

        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        guard ipPart.range(of: pattern, options: .regularExpression) != nil else { return false }

        let octets = ipPart.split(separator: ".")
        for octet in octets {
            guard let val = Int(octet), val <= 255 else { return false }
        }

        if parts.count == 2 {
            guard let cidr = Int(parts[1]), cidr <= 32 else { return false }
        }

        return true
    }

    private static func isValidIPv6CIDR(_ input: String) -> Bool {
        let parts = input.split(separator: "/", maxSplits: 1)
        let ipPart = String(parts[0])

        var addr = in6_addr()
        guard inet_pton(AF_INET6, ipPart, &addr) == 1 else { return false }

        if parts.count == 2 {
            guard let prefix = Int(parts[1]), prefix >= 0, prefix <= 128 else { return false }
        }

        return true
    }
}
