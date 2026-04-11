import Foundation

/// The protocol type that discovered the device.
enum DiscoveryProtocol: String, Codable {
    case cdp = "CDP"
    case lldp = "LLDP"
}

/// Represents a network device discovered via CDP or LLDP.
struct DiscoveredDevice: Identifiable {
    let id = UUID()
    var timestamp: Date
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

    /// Tracks all protocols that have contributed data to this device.
    var seenProtocols: Set<DiscoveryProtocol> = []

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
        self.seenProtocols = [protocolType]
    }

    /// A human-readable title for this device.
    var displayTitle: String {
        systemName ?? deviceId ?? chassisId ?? sourceMac
    }

    /// Convert to the Codable DTO for XPC transport.
    func toInfo() -> DiscoveredDeviceInfo {
        let protoLabel = seenProtocols.count > 1
            ? seenProtocols.sorted(by: { $0.rawValue < $1.rawValue }).map(\.rawValue).joined(separator: "+")
            : protocolType.rawValue

        return DiscoveredDeviceInfo(
            protocolType: protoLabel,
            sourceInterface: sourceInterface,
            sourceMac: sourceMac,
            timestamp: timestamp,
            deviceId: deviceId,
            portId: portId,
            portDescription: portDescription,
            systemName: systemName,
            systemDescription: systemDescription,
            managementAddresses: managementAddresses,
            capabilities: capabilities,
            ttl: ttl,
            platform: platform,
            nativeVlan: nativeVlan,
            duplex: duplex,
            softwareVersion: softwareVersion,
            vtpDomain: vtpDomain,
            powerAvailable: powerAvailable,
            chassisId: chassisId,
            chassisIdSubtype: chassisIdSubtype,
            portIdSubtype: portIdSubtype,
            organizationalTLVs: organizationalTLVs.map {
                DiscoveredDeviceInfo.OrganizationalTLVInfo(
                    oui: $0.oui,
                    subtype: $0.subtype,
                    description: $0.description,
                    value: $0.value
                )
            })
    }

    /// Merge fields from a new discovery into this device, keeping existing non-nil values
    /// except for VLAN which always updates. This combines CDP and LLDP data so fields
    /// from one protocol persist when the other protocol's packet arrives.
    mutating func merge(from other: DiscoveredDevice) {
        timestamp = other.timestamp
        ttl = other.ttl

        // Track both protocols
        if other.protocolType != protocolType {
            seenProtocols.insert(other.protocolType)
        }

        // VLAN always updates (can change dynamically)
        nativeVlan = other.nativeVlan ?? nativeVlan

        // Fill in any fields that were previously nil
        deviceId = deviceId ?? other.deviceId
        portId = portId ?? other.portId
        portDescription = portDescription ?? other.portDescription
        systemName = systemName ?? other.systemName
        systemDescription = systemDescription ?? other.systemDescription
        platform = platform ?? other.platform
        duplex = duplex ?? other.duplex
        softwareVersion = softwareVersion ?? other.softwareVersion
        vtpDomain = vtpDomain ?? other.vtpDomain
        powerAvailable = powerAvailable ?? other.powerAvailable
        chassisId = chassisId ?? other.chassisId
        chassisIdSubtype = chassisIdSubtype ?? other.chassisIdSubtype
        portIdSubtype = portIdSubtype ?? other.portIdSubtype

        // Merge arrays: union and deduplicate
        let allAddresses = NSOrderedSet(array: managementAddresses + other.managementAddresses)
        managementAddresses = allAddresses.array as! [String]
        let allCapabilities = NSOrderedSet(array: capabilities + other.capabilities)
        capabilities = allCapabilities.array as! [String]
        if other.organizationalTLVs.count > organizationalTLVs.count {
            organizationalTLVs = other.organizationalTLVs
        }
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
