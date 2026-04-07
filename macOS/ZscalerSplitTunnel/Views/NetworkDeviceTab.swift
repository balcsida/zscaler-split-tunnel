import SwiftUI

struct NetworkDeviceTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            if let device = appState.helperStatus?.discoveredDevice {
                deviceSection(device)
                tlvSection(device)
            } else {
                emptyState
            }

            menuBarFieldsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Discovered Device

    private func deviceSection(_ device: DiscoveredDeviceInfo) -> some View {
        Section("Discovered Device") {
            LabeledContent("Device Name") {
                Text(device.displayTitle)
                    .textSelection(.enabled)
            }

            if let deviceId = device.deviceId, deviceId != device.displayTitle {
                LabeledContent("Device ID") {
                    Text(deviceId).textSelection(.enabled)
                }
            }

            if let systemName = device.systemName, systemName != device.displayTitle {
                LabeledContent("System Name") {
                    Text(systemName).textSelection(.enabled)
                }
            }

            LabeledContent("Protocol") {
                Text(device.protocolType)
            }

            LabeledContent("Source Interface") {
                Text(device.sourceInterface)
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("Source MAC") {
                Text(device.sourceMac)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            if let portId = device.portId {
                LabeledContent("Port ID") {
                    Text(portId).textSelection(.enabled)
                }
            }

            if let portDesc = device.portDescription {
                LabeledContent("Port Description") {
                    Text(portDesc).textSelection(.enabled)
                }
            }

            if let vlan = device.nativeVlan {
                LabeledContent("Native VLAN") {
                    Text("\(vlan)")
                }
            }

            if let duplex = device.duplex {
                LabeledContent("Duplex") {
                    Text(duplex)
                }
            }

            if let platform = device.platform {
                LabeledContent("Platform") {
                    Text(platform).textSelection(.enabled)
                }
            }

            if let version = device.softwareVersion {
                LabeledContent("Software Version") {
                    Text(version).textSelection(.enabled)
                }
            }

            if let vtp = device.vtpDomain {
                LabeledContent("VTP Domain") {
                    Text(vtp).textSelection(.enabled)
                }
            }

            if let power = device.powerAvailable {
                LabeledContent("Power Available") {
                    Text(power)
                }
            }

            if !device.capabilities.isEmpty {
                LabeledContent("Capabilities") {
                    Text(device.capabilities.joined(separator: ", "))
                }
            }

            if !device.managementAddresses.isEmpty {
                ForEach(Array(device.managementAddresses.enumerated()), id: \.offset) { index, addr in
                    LabeledContent(index == 0 ? "Management Address" : "") {
                        Text(addr)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if let chassisId = device.chassisId {
                LabeledContent("Chassis ID") {
                    Text(chassisId)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let ttl = device.ttl {
                LabeledContent("TTL") {
                    Text("\(ttl)s")
                }
            }

            LabeledContent("Discovered") {
                Text(device.timestamp, style: .relative)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Organizational TLVs

    @ViewBuilder
    private func tlvSection(_ device: DiscoveredDeviceInfo) -> some View {
        if !device.organizationalTLVs.isEmpty {
            Section("Organizational TLVs") {
                ForEach(Array(device.organizationalTLVs.enumerated()), id: \.offset) { _, tlv in
                    LabeledContent("\(tlv.oui) / \(tlv.subtype)") {
                        VStack(alignment: .trailing) {
                            Text(tlv.description)
                                .foregroundStyle(.secondary)
                            Text(tlv.value)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Section("Discovered Device") {
            VStack(spacing: 8) {
                Image(systemName: "wifi.router")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No device discovered")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Connect via Ethernet to detect network switches via CDP/LLDP")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Menu Bar Fields

    private var menuBarFieldsSection: some View {
        Section("Menu Bar Fields") {
            ForEach(DeviceField.allCases, id: \.self) { field in
                Toggle(isOn: Binding(
                    get: { appState.deviceFieldPreferences.isEnabled(field) },
                    set: { _ in appState.deviceFieldPreferences.toggle(field) }
                )) {
                    Label(field.label, systemImage: field.icon)
                }
            }
        }
    }
}
