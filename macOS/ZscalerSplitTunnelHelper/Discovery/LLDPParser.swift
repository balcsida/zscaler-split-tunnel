import Foundation

/// Parses LLDP (Link Layer Discovery Protocol) frames.
///
/// LLDP frame structure (after Ethernet header with EtherType 0x88CC):
///   - TLVs: type(7 bits) + length(9 bits) in first 2 bytes, then value
///   - Mandatory TLVs: Chassis ID (1), Port ID (2), TTL (3)
///   - End of LLDPDU: type 0, length 0
enum LLDPParser {

    private enum TLVType: Int {
        case endOfLLDPDU      = 0
        case chassisId        = 1
        case portId           = 2
        case ttl              = 3
        case portDescription  = 4
        case systemName       = 5
        case systemDescription = 6
        case systemCapabilities = 7
        case managementAddress = 8
        case organizational   = 127
    }

    // Chassis ID subtypes
    private enum ChassisIdSubtype: UInt8 {
        case chassisComponent = 1
        case interfaceAlias   = 2
        case portComponent    = 3
        case macAddress       = 4
        case networkAddress   = 5
        case interfaceName    = 6
        case local            = 7
    }

    // Port ID subtypes
    private enum PortIdSubtype: UInt8 {
        case interfaceAlias   = 1
        case portComponent    = 2
        case macAddress       = 3
        case networkAddress   = 4
        case interfaceName    = 5
        case agentCircuitId   = 6
        case local            = 7
    }

    /// Parse an LLDP frame from raw bytes starting after the Ethernet header.
    /// The `data` parameter should begin right after the EtherType (0x88CC).
    static func parse(
        data: Data,
        sourceInterface: String,
        sourceMac: String
    ) -> DiscoveredDevice? {
        guard data.count >= 2 else { return nil }

        var device = DiscoveredDevice(
            sourceInterface: sourceInterface,
            protocolType: .lldp,
            sourceMac: sourceMac
        )

        var offset = 0

        while offset + 2 <= data.count {
            let headerWord = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let tlvType = Int(headerWord >> 9)
            let tlvLength = Int(headerWord & 0x01FF)
            offset += 2

            guard offset + tlvLength <= data.count else { break }

            if tlvType == TLVType.endOfLLDPDU.rawValue {
                break
            }

            let valueData = data.subdata(in: offset..<(offset + tlvLength))

            switch TLVType(rawValue: tlvType) {
            case .chassisId:
                parseChassisId(valueData, into: &device)
            case .portId:
                parsePortId(valueData, into: &device)
            case .ttl:
                if tlvLength >= 2 {
                    device.ttl = Int(UInt16(valueData[0]) << 8 | UInt16(valueData[1]))
                }
            case .portDescription:
                device.portDescription = String(data: valueData, encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters)
            case .systemName:
                device.systemName = String(data: valueData, encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters)
            case .systemDescription:
                device.systemDescription = String(data: valueData, encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters)
            case .systemCapabilities:
                device.capabilities = parseCapabilities(valueData)
            case .managementAddress:
                if let addr = parseManagementAddress(valueData) {
                    device.managementAddresses.append(addr)
                }
            case .organizational:
                if let orgTLV = parseOrganizational(valueData) {
                    device.organizationalTLVs.append(orgTLV)
                    applyOrgTLV(orgTLV, to: &device)
                }
            default:
                break
            }

            offset += tlvLength
        }

        return device
    }

    // MARK: - Chassis ID

    private static func parseChassisId(_ data: Data, into device: inout DiscoveredDevice) {
        guard data.count >= 2 else { return }
        let subtype = data[0]
        let valueData = data.subdata(in: 1..<data.count)

        switch ChassisIdSubtype(rawValue: subtype) {
        case .macAddress:
            device.chassisId = formatMAC(valueData)
            device.chassisIdSubtype = "MAC Address"
        case .networkAddress:
            device.chassisId = parseNetworkAddress(valueData)
            device.chassisIdSubtype = "Network Address"
        case .interfaceName, .interfaceAlias, .local:
            device.chassisId = String(data: valueData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
            device.chassisIdSubtype = subtypeName(subtype)
        default:
            device.chassisId = valueData.map { String(format: "%02x", $0) }.joined(separator: ":")
            device.chassisIdSubtype = subtypeName(subtype)
        }
    }

    private static func subtypeName(_ subtype: UInt8) -> String {
        switch ChassisIdSubtype(rawValue: subtype) {
        case .chassisComponent: return "Chassis Component"
        case .interfaceAlias: return "Interface Alias"
        case .portComponent: return "Port Component"
        case .macAddress: return "MAC Address"
        case .networkAddress: return "Network Address"
        case .interfaceName: return "Interface Name"
        case .local: return "Local"
        default: return "Unknown (\(subtype))"
        }
    }

    // MARK: - Port ID

    private static func parsePortId(_ data: Data, into device: inout DiscoveredDevice) {
        guard data.count >= 2 else { return }
        let subtype = data[0]
        let valueData = data.subdata(in: 1..<data.count)

        switch PortIdSubtype(rawValue: subtype) {
        case .macAddress:
            device.portId = formatMAC(valueData)
            device.portIdSubtype = "MAC Address"
        case .networkAddress:
            device.portId = parseNetworkAddress(valueData)
            device.portIdSubtype = "Network Address"
        case .interfaceName, .interfaceAlias, .local, .agentCircuitId, .portComponent:
            device.portId = String(data: valueData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
            device.portIdSubtype = portSubtypeName(subtype)
        default:
            device.portId = valueData.map { String(format: "%02x", $0) }.joined(separator: ":")
            device.portIdSubtype = portSubtypeName(subtype)
        }
    }

    private static func portSubtypeName(_ subtype: UInt8) -> String {
        switch PortIdSubtype(rawValue: subtype) {
        case .interfaceAlias: return "Interface Alias"
        case .portComponent: return "Port Component"
        case .macAddress: return "MAC Address"
        case .networkAddress: return "Network Address"
        case .interfaceName: return "Interface Name"
        case .agentCircuitId: return "Agent Circuit ID"
        case .local: return "Local"
        default: return "Unknown (\(subtype))"
        }
    }

    // MARK: - System Capabilities

    private static func parseCapabilities(_ data: Data) -> [String] {
        guard data.count >= 2 else { return [] }
        // First 2 bytes: system capabilities, next 2 bytes: enabled capabilities
        let enabled: UInt16
        if data.count >= 4 {
            enabled = UInt16(data[2]) << 8 | UInt16(data[3])
        } else {
            enabled = UInt16(data[0]) << 8 | UInt16(data[1])
        }

        var caps: [String] = []
        if enabled & 0x0001 != 0 { caps.append("Other") }
        if enabled & 0x0002 != 0 { caps.append("Repeater") }
        if enabled & 0x0004 != 0 { caps.append("MAC Bridge") }
        if enabled & 0x0008 != 0 { caps.append("WLAN Access Point") }
        if enabled & 0x0010 != 0 { caps.append("Router") }
        if enabled & 0x0020 != 0 { caps.append("Telephone") }
        if enabled & 0x0040 != 0 { caps.append("DOCSIS Cable Device") }
        if enabled & 0x0080 != 0 { caps.append("Station Only") }
        if enabled & 0x0100 != 0 { caps.append("C-VLAN Component") }
        if enabled & 0x0200 != 0 { caps.append("S-VLAN Component") }
        if enabled & 0x0400 != 0 { caps.append("Two-Port MAC Relay") }
        return caps
    }

    // MARK: - Management Address

    private static func parseManagementAddress(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let addrStringLen = Int(data[0])
        guard addrStringLen >= 2, data.count >= 1 + addrStringLen else { return nil }

        let addrSubtype = data[1]
        let addrData = data.subdata(in: 2..<(1 + addrStringLen))

        switch addrSubtype {
        case 1: // IPv4
            if addrData.count == 4 {
                return "\(addrData[0]).\(addrData[1]).\(addrData[2]).\(addrData[3])"
            }
        case 2: // IPv6
            if addrData.count == 16 {
                var parts: [String] = []
                for i in stride(from: 0, to: 16, by: 2) {
                    let word = UInt16(addrData[i]) << 8 | UInt16(addrData[i + 1])
                    parts.append(String(format: "%x", word))
                }
                return parts.joined(separator: ":")
            }
        default:
            break
        }

        return addrData.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: - Organizational TLVs

    private static func parseOrganizational(_ data: Data) -> OrganizationalTLV? {
        guard data.count >= 4 else { return nil }
        let oui = String(format: "%02x-%02x-%02x", data[0], data[1], data[2])
        let subtype = Int(data[3])
        let valueData = data.subdata(in: 4..<data.count)

        let (desc, value) = describeOrgTLV(oui: oui, subtype: subtype, data: valueData)

        return OrganizationalTLV(
            oui: oui,
            subtype: subtype,
            description: desc,
            value: value
        )
    }

    private static func describeOrgTLV(oui: String, subtype: Int, data: Data) -> (String, String) {
        // IEEE 802.1
        if oui == "00-80-c2" {
            switch subtype {
            case 1:
                if data.count >= 2 {
                    let vlan = Int(UInt16(data[0]) << 8 | UInt16(data[1]))
                    return ("Port VLAN ID", "\(vlan)")
                }
            case 3:
                return ("VLAN Name", String(data: data, encoding: .utf8) ?? data.hexString)
            case 4:
                return ("Protocol Identity", data.hexString)
            default:
                break
            }
        }

        // IEEE 802.3
        if oui == "00-12-0f" {
            switch subtype {
            case 1: return ("MAC/PHY Config", data.hexString)
            case 2: return ("Power via MDI", data.hexString)
            case 3:
                if data.count >= 2 {
                    let maxFrameSize = Int(UInt16(data[0]) << 8 | UInt16(data[1]))
                    return ("Max Frame Size", "\(maxFrameSize)")
                }
            case 4: return ("EEE", data.hexString)
            default: break
            }
        }

        // Cisco
        if oui == "00-01-42" {
            switch subtype {
            case 1: return ("Cisco Power", data.hexString)
            default: break
            }
        }

        return ("OUI \(oui) Subtype \(subtype)", data.hexString)
    }

    /// Apply well-known organizational TLV values to the device model.
    private static func applyOrgTLV(_ tlv: OrganizationalTLV, to device: inout DiscoveredDevice) {
        // Port VLAN ID from IEEE 802.1
        if tlv.oui == "00-80-c2" && tlv.subtype == 1, let vlan = Int(tlv.value) {
            device.nativeVlan = vlan
        }
    }

    // MARK: - Helpers

    private static func formatMAC(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func parseNetworkAddress(_ data: Data) -> String? {
        guard data.count >= 1 else { return nil }
        let family = data[0]
        let addrData = data.subdata(in: 1..<data.count)

        if family == 1, addrData.count >= 4 {
            return "\(addrData[0]).\(addrData[1]).\(addrData[2]).\(addrData[3])"
        }
        return addrData.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
