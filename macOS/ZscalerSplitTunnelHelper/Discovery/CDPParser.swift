import Foundation

/// Parses CDP (Cisco Discovery Protocol) frames.
///
/// CDP frame structure (after Ethernet header):
///   - DSAP: 0xAA, SSAP: 0xAA, Control: 0x03 (802.2 SNAP)
///   - OUI: 0x00 0x00 0x0C (Cisco)
///   - Protocol ID: 0x2000 (CDP)
///   - Version: 1 byte
///   - TTL: 1 byte
///   - Checksum: 2 bytes
///   - TLVs: type(2) + length(2) + value(length-4)
enum CDPParser {

    // CDP TLV types
    private enum TLVType: UInt16 {
        case deviceId       = 0x0001
        case addresses      = 0x0002
        case portId         = 0x0003
        case capabilities   = 0x0004
        case softwareVersion = 0x0005
        case platform       = 0x0006
        case managementAddr = 0x0016
        case nativeVlan     = 0x000A
        case duplex         = 0x000B
        case vtpDomain      = 0x0009
        case powerAvailable = 0x001A
        case systemName     = 0x0014
    }

    /// Parse a CDP frame from raw bytes starting after the Ethernet header.
    /// The `data` parameter should begin at the 802.2 LLC header (DSAP).
    static func parse(
        data: Data,
        sourceInterface: String,
        sourceMac: String
    ) -> DiscoveredDevice? {
        // Validate minimum length: 8 bytes LLC/SNAP + 4 bytes CDP header
        guard data.count >= 12 else { return nil }

        var offset = 0

        // 802.2 LLC SNAP header: DSAP(1) SSAP(1) Control(1) OUI(3) PID(2) = 8 bytes
        let dsap = data[offset]
        let ssap = data[offset + 1]
        guard dsap == 0xAA, ssap == 0xAA else { return nil }
        offset += 8 // Skip past SNAP header

        // CDP header
        guard offset + 4 <= data.count else { return nil }
        // let version = data[offset]
        let ttl = Int(data[offset + 1])
        // let checksum = readUInt16(data, offset: offset + 2)
        offset += 4

        var device = DiscoveredDevice(
            sourceInterface: sourceInterface,
            protocolType: .cdp,
            sourceMac: sourceMac
        )
        device.ttl = ttl

        // Parse TLVs
        while offset + 4 <= data.count {
            let tlvType = readUInt16(data, offset: offset)
            let tlvLength = Int(readUInt16(data, offset: offset + 2))

            guard tlvLength >= 4, offset + tlvLength <= data.count else { break }

            let valueData = data.subdata(in: (offset + 4)..<(offset + tlvLength))

            switch TLVType(rawValue: tlvType) {
            case .deviceId:
                device.deviceId = String(data: valueData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            case .portId:
                device.portId = String(data: valueData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            case .softwareVersion:
                device.softwareVersion = String(data: valueData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            case .platform:
                device.platform = String(data: valueData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            case .capabilities:
                device.capabilities = parseCapabilities(valueData)
            case .addresses, .managementAddr:
                device.managementAddresses.append(contentsOf: parseAddresses(valueData))
            case .nativeVlan:
                if valueData.count >= 2 {
                    device.nativeVlan = Int(readUInt16(valueData, offset: 0))
                }
            case .duplex:
                if valueData.count >= 1 {
                    device.duplex = valueData[0] == 1 ? "Full" : "Half"
                }
            case .vtpDomain:
                device.vtpDomain = String(data: valueData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            case .systemName:
                device.systemName = String(data: valueData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            default:
                break
            }

            offset += tlvLength
        }

        return device
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        return UInt16(data[data.startIndex + offset]) << 8
             | UInt16(data[data.startIndex + offset + 1])
    }

    /// Parse CDP capability flags into human-readable strings.
    private static func parseCapabilities(_ data: Data) -> [String] {
        guard data.count >= 4 else { return [] }
        let flags = UInt32(data[0]) << 24
                  | UInt32(data[1]) << 16
                  | UInt32(data[2]) << 8
                  | UInt32(data[3])

        var caps: [String] = []
        if flags & 0x01 != 0 { caps.append("Router") }
        if flags & 0x02 != 0 { caps.append("Transparent Bridge") }
        if flags & 0x04 != 0 { caps.append("Source Route Bridge") }
        if flags & 0x08 != 0 { caps.append("L2 Switch") }
        if flags & 0x10 != 0 { caps.append("Host") }
        if flags & 0x20 != 0 { caps.append("IGMP Snooping") }
        if flags & 0x40 != 0 { caps.append("Repeater") }
        if flags & 0x80 != 0 { caps.append("VoIP Phone") }
        if flags & 0x100 != 0 { caps.append("Remotely Managed") }
        if flags & 0x200 != 0 { caps.append("CVTA/STP Dispute") }
        if flags & 0x400 != 0 { caps.append("Two-Port Mac Relay") }
        return caps
    }

    /// Parse CDP address TLV.
    /// Format: count(4) + [ protocol_type(1) + proto_len(1) + protocol(proto_len)
    ///                       + addr_len(2) + address(addr_len) ] ...
    private static func parseAddresses(_ data: Data) -> [String] {
        guard data.count >= 4 else { return [] }
        let count = Int(UInt32(data[0]) << 24
                      | UInt32(data[1]) << 16
                      | UInt32(data[2]) << 8
                      | UInt32(data[3]))

        var addresses: [String] = []
        var offset = 4

        for _ in 0..<count {
            // protocol type (1) + protocol length (1)
            guard offset + 2 <= data.count else { break }
            // let protocolType = data[offset]
            let protoLen = Int(data[offset + 1])
            offset += 2

            // skip protocol bytes
            guard offset + protoLen <= data.count else { break }
            offset += protoLen

            // address length (2)
            guard offset + 2 <= data.count else { break }
            let addrLen = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            offset += 2

            guard offset + addrLen <= data.count else { break }

            if addrLen == 4 {
                // IPv4
                let addr = "\(data[offset]).\(data[offset+1]).\(data[offset+2]).\(data[offset+3])"
                addresses.append(addr)
            } else {
                // Hex representation for non-IPv4
                let hex = data[offset..<(offset + addrLen)].map { String(format: "%02x", $0) }.joined(separator: ":")
                addresses.append(hex)
            }
            offset += addrLen
        }

        return addresses
    }
}
