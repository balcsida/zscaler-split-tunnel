import Foundation

enum ZscalerInterface {
    // A stale host route can shadow 100.64.1.3 and point it at Wi-Fi.
    // Query the tunnel network itself, then reject unrelated/default routes.
    static let routeArguments = ["-n", "get", "-net", "100.64.0.0/16"]

    static func parse(_ output: String) -> String? {
        var fields: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard fields["destination"] == "100.64.0.0",
              fields["mask"] == "255.255.0.0",
              let interface = fields["interface"], interface.hasPrefix("utun") else { return nil }
        return interface
    }
}
