import Foundation

enum ConfigEntry: Hashable, Sendable {
    case domain(String)
    case ip(String)
    case cidr(String)
    case url(String)
    case wildcard(String)

    var displayString: String {
        switch self {
        case .domain(let value),
             .ip(let value),
             .cidr(let value),
             .url(let value),
             .wildcard(let value):
            return value
        }
    }

    static func parse(_ line: String) -> ConfigEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        // URL check
        if IPValidation.isValidURL(trimmed) {
            return .url(trimmed)
        }

        // Wildcard domain: *.example.com or .example.com
        if trimmed.hasPrefix("*.") || trimmed.hasPrefix(".") {
            let domainPart = trimmed.hasPrefix("*.") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst())
            if IPValidation.isValidDomain(domainPart) {
                return .wildcard(trimmed)
            }
        }

        // CIDR notation (must contain /)
        if trimmed.contains("/"), IPValidation.isValidCIDR(trimmed) {
            return .cidr(trimmed)
        }

        // Plain IP
        if IPValidation.isValidIPv4(trimmed) || IPValidation.isValidIPv6(trimmed) {
            return .ip(trimmed)
        }

        // Domain
        if IPValidation.isValidDomain(trimmed) {
            return .domain(trimmed)
        }

        return nil
    }
}
