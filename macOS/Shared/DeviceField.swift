import Foundation

enum DeviceField: String, CaseIterable, Codable, Sendable {
    case portId
    case nativeVlan
    case platform
    case protocolType
    case managementIP
    case sourceInterface
    case duplex

    var label: String {
        switch self {
        case .portId: return "Port"
        case .nativeVlan: return "VLAN"
        case .platform: return "Platform"
        case .protocolType: return "Protocol"
        case .managementIP: return "Mgmt IP"
        case .sourceInterface: return "Interface"
        case .duplex: return "Duplex"
        }
    }

    var icon: String {
        switch self {
        case .portId: return "cable.connector"
        case .nativeVlan: return "number"
        case .platform: return "cpu"
        case .protocolType: return "antenna.radiowaves.left.and.right"
        case .managementIP: return "network"
        case .sourceInterface: return "rectangle.connected.to.line.below"
        case .duplex: return "arrow.left.arrow.right"
        }
    }

    func value(from device: DiscoveredDeviceInfo) -> String? {
        switch self {
        case .portId: return device.portId
        case .nativeVlan: return device.nativeVlan.map { "VLAN \($0)" }
        case .platform: return device.platform
        case .protocolType: return device.protocolType
        case .managementIP: return device.managementAddresses.first
        case .sourceInterface: return device.sourceInterface
        case .duplex: return device.duplex
        }
    }

    static let defaultEnabled: Set<DeviceField> = [.portId, .nativeVlan, .platform]
}
