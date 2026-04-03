import Foundation

/// The protocol type that discovered the device.
enum DiscoveryProtocol: String, Codable {
    case cdp = "CDP"
    case lldp = "LLDP"
}

/// Represents a network device discovered via CDP or LLDP.
struct DiscoveredDevice: Identifiable {
    let id = UUID()
    let timestamp: Date
    let sourceInterface: String
    let protocolType: DiscoveryProtocol
    let sourceMac: String

    // Common fields
    var deviceId: String?
    var portId: String?
    var portDescription: String?
    var systemName: String?
    var systemDescription: String?
    var managementAddresses: [String]
    var capabilities: [String]
    var ttl: Int?

    // CDP-specific fields
    var platform: String?
    var nativeVlan: Int?
    var duplex: String?
    var softwareVersion: String?
    var vtpDomain: String?
    var powerAvailable: String?

    // LLDP-specific fields
    var chassisId: String?
    var chassisIdSubtype: String?
    var portIdSubtype: String?
    var organizationalTLVs: [OrganizationalTLV]

    init(
        timestamp: Date = Date(),
        sourceInterface: String,
        protocolType: DiscoveryProtocol,
        sourceMac: String
    ) {
        self.timestamp = timestamp
        self.sourceInterface = sourceInterface
        self.protocolType = protocolType
        self.sourceMac = sourceMac
        self.managementAddresses = []
        self.capabilities = []
        self.organizationalTLVs = []
    }

    /// A human-readable title for this device.
    var displayTitle: String {
        systemName ?? deviceId ?? chassisId ?? sourceMac
    }

    /// A short summary line.
    var summary: String {
        var parts: [String] = []
        if let portId = portId {
            parts.append("Port: \(portId)")
        }
        if let platform = platform {
            parts.append(platform)
        }
        if !managementAddresses.isEmpty {
            parts.append(managementAddresses.first!)
        }
        return parts.joined(separator: " | ")
    }
}

/// Represents an LLDP organizational-specific TLV.
struct OrganizationalTLV: Identifiable {
    let id = UUID()
    let oui: String
    let subtype: Int
    let description: String
    let value: String
}
