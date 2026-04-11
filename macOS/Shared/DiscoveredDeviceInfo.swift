import Foundation

/// Codable DTO for discovered network device data, passed from helper to app via XPC.
struct DiscoveredDeviceInfo: Codable, Sendable {
    // Meta
    var protocolType: String // "CDP", "LLDP", or a merged label like "CDP+LLDP"
    var sourceInterface: String
    var sourceMac: String
    var timestamp: Date

    // Common fields
    var deviceId: String?
    var portId: String?
    var portDescription: String?
    var systemName: String?
    var systemDescription: String?
    var managementAddresses: [String]
    var capabilities: [String]
    var ttl: Int?

    // CDP-specific
    var platform: String?
    var nativeVlan: Int?
    var duplex: String?
    var softwareVersion: String?
    var vtpDomain: String?
    var powerAvailable: String?

    // LLDP-specific
    var chassisId: String?
    var chassisIdSubtype: String?
    var portIdSubtype: String?
    var organizationalTLVs: [OrganizationalTLVInfo]

    struct OrganizationalTLVInfo: Codable, Sendable {
        var oui: String
        var subtype: Int
        var description: String
        var value: String
    }

    /// A human-readable title for this device.
    var displayTitle: String {
        systemName ?? deviceId ?? chassisId ?? sourceMac
    }
}
