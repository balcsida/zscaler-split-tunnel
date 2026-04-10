# Network Device Info Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose full CDP/LLDP discovered device data to the frontend and display it in a menu bar summary + Settings tab with configurable field visibility.

**Architecture:** Create a `DiscoveredDeviceInfo` Codable struct in Shared (serialization DTO), add it to `HelperStatus`, build a `DeviceField` enum + UserDefaults preferences wrapper, add a `DisclosureGroup` to `MenuBarView`, and create a new `NetworkDeviceTab` in Settings. The existing `DiscoveredDevice` stays in the helper — the helper converts it to the DTO in `getStatus()`.

**Tech Stack:** Swift, SwiftUI, NSXPCConnection (existing), UserDefaults, JSONEncoder/Decoder

---

## Task 1: Create `DiscoveredDeviceInfo` Codable DTO in Shared

**Files:**
- Create: `macOS/Shared/DiscoveredDeviceInfo.swift`
- Modify: `macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj` (add file to both targets)

- [ ] **Step 1: Create the DTO file**

Create `macOS/Shared/DiscoveredDeviceInfo.swift`:

```swift
import Foundation

/// Codable DTO for discovered network device data, passed from helper to app via XPC.
struct DiscoveredDeviceInfo: Codable, Sendable {
    // Meta
    var protocolType: String // "CDP" or "LLDP"
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
```

- [ ] **Step 2: Add file to Xcode project (both targets)**

Add the new file reference and build file entries to `project.pbxproj`. The file needs to compile in both the `ZscalerSplitTunnel` app target (build phase `B32C15492973C02A2DB4A519`) and the `ZscalerSplitTunnelHelper` target (build phase `D811AB1B0CBBE07882BDCF61`), and be listed in the Shared group (`C5D0291D84787FAA0AB6D238`).

Generate unique IDs for:
- PBXFileReference: use `A1B2C3D4E5F6A7B8C9D0E1F2` for the file ref
- PBXBuildFile (app target): use `D1E2F3A4B5C6D7E8F9A0B1C2`
- PBXBuildFile (helper target): use `E2F3A4B5C6D7E8F9A0B1C2D3`

- [ ] **Step 3: Commit**

```bash
git add macOS/Shared/DiscoveredDeviceInfo.swift macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj
git commit -m "feat: add DiscoveredDeviceInfo Codable DTO in Shared"
```

---

## Task 2: Add `discoveredDevice` to `HelperStatus` and populate in `HelperTool`

**Files:**
- Modify: `macOS/Shared/XPCTypes.swift:11-31` (add field to HelperStatus)
- Modify: `macOS/ZscalerSplitTunnelHelper/HelperTool.swift:79-112` (populate in getStatus)

- [ ] **Step 1: Add field to HelperStatus**

In `macOS/Shared/XPCTypes.swift`, add a new optional field to `HelperStatus` after `officeWifiGateway`:

```swift
var officeWifiGateway: String?
var discoveredDevice: DiscoveredDeviceInfo?  // <-- add this line
```

- [ ] **Step 2: Add conversion method to DiscoveredDevice**

In `macOS/ZscalerSplitTunnelHelper/Discovery/DiscoveredDevice.swift`, add a method at the end of the struct (before the closing `}`):

```swift
/// Convert to the Codable DTO for XPC transport.
func toInfo() -> DiscoveredDeviceInfo {
    DiscoveredDeviceInfo(
        protocolType: protocolType.rawValue,
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
        }
    )
}
```

- [ ] **Step 3: Populate discoveredDevice in HelperTool.getStatus()**

In `macOS/ZscalerSplitTunnelHelper/HelperTool.swift`, in the `getStatus` method, add `discoveredDevice` to the `HelperStatus` initializer. Change the init call (line 84-103) to include:

```swift
officeWifiGateway: snapshot.officeWifiGateway,
discoveredDevice: snapshot.lastDiscoveredDevice?.toInfo()
```

Replace the existing `officeWifiGateway` line (which is the last parameter) and add `discoveredDevice` after it.

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -project macOS/ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnelHelper -configuration Debug build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add macOS/Shared/XPCTypes.swift macOS/ZscalerSplitTunnelHelper/Discovery/DiscoveredDevice.swift macOS/ZscalerSplitTunnelHelper/HelperTool.swift
git commit -m "feat: expose discovered device data through HelperStatus"
```

---

## Task 3: Create `DeviceField` enum and preferences wrapper

**Files:**
- Create: `macOS/Shared/DeviceField.swift`
- Create: `macOS/ZscalerSplitTunnel/ViewModels/DeviceFieldPreferences.swift`
- Modify: `macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj` (add both files)

- [ ] **Step 1: Create DeviceField enum**

Create `macOS/Shared/DeviceField.swift`:

```swift
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
```

- [ ] **Step 2: Create DeviceFieldPreferences**

Create `macOS/ZscalerSplitTunnel/ViewModels/DeviceFieldPreferences.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class DeviceFieldPreferences {
    private static let key = "menuBarDeviceFields"

    var enabledFields: Set<DeviceField> {
        didSet { save() }
    }

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: Self.key) {
            enabledFields = Set(stored.compactMap { DeviceField(rawValue: $0) })
        } else {
            enabledFields = DeviceField.defaultEnabled
        }
    }

    func isEnabled(_ field: DeviceField) -> Bool {
        enabledFields.contains(field)
    }

    func toggle(_ field: DeviceField) {
        if enabledFields.contains(field) {
            enabledFields.remove(field)
        } else {
            enabledFields.insert(field)
        }
    }

    private func save() {
        UserDefaults.standard.set(
            enabledFields.map(\.rawValue),
            forKey: Self.key
        )
    }
}
```

- [ ] **Step 3: Add both files to Xcode project**

Add file references and build file entries to `project.pbxproj`:

For `DeviceField.swift` (Shared — both targets):
- PBXFileReference: `F1A2B3C4D5E6F7A8B9C0D1E2`
- PBXBuildFile (app): `A2B3C4D5E6F7A8B9C0D1E2F3`
- PBXBuildFile (helper): `B3C4D5E6F7A8B9C0D1E2F3A4`
- Add to Shared group `C5D0291D84787FAA0AB6D238`

For `DeviceFieldPreferences.swift` (App target only):
- PBXFileReference: `C4D5E6F7A8B9C0D1E2F3A4B5`
- PBXBuildFile (app): `D5E6F7A8B9C0D1E2F3A4B5C6`
- Add to ViewModels group

- [ ] **Step 4: Commit**

```bash
git add macOS/Shared/DeviceField.swift macOS/ZscalerSplitTunnel/ViewModels/DeviceFieldPreferences.swift macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj
git commit -m "feat: add DeviceField enum and preferences wrapper"
```

---

## Task 4: Wire `DeviceFieldPreferences` into `AppState`

**Files:**
- Modify: `macOS/ZscalerSplitTunnel/ViewModels/AppState.swift:8` (add property)

- [ ] **Step 1: Add preferences to AppState**

In `macOS/ZscalerSplitTunnel/ViewModels/AppState.swift`, add a new property after `isLoading`:

```swift
var isLoading: Bool = false
let deviceFieldPreferences = DeviceFieldPreferences()  // <-- add this line
```

- [ ] **Step 2: Commit**

```bash
git add macOS/ZscalerSplitTunnel/ViewModels/AppState.swift
git commit -m "feat: wire DeviceFieldPreferences into AppState"
```

---

## Task 5: Add device detail `DisclosureGroup` to `MenuBarView`

**Files:**
- Modify: `macOS/ZscalerSplitTunnel/Views/MenuBarView.swift:68-82` (add disclosure group in status section)

- [ ] **Step 1: Add the disclosure group**

In `macOS/ZscalerSplitTunnel/Views/MenuBarView.swift`, inside the `statusSection` computed property, after the WiFi GW `StatusRow` (after line 81: `}`) and before the closing `}` of the `if status.officeMode != .disabled` block, add the device details disclosure group:

```swift
if let device = status.discoveredDevice {
    DisclosureGroup("Device Details") {
        ForEach(DeviceField.allCases.filter {
            appState.deviceFieldPreferences.isEnabled($0)
        }, id: \.self) { field in
            if let fieldValue = field.value(from: device) {
                StatusRow(icon: field.icon, label: field.label,
                          value: fieldValue)
            }
        }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
}
```

Insert this after the `officeWifiGateway` block (after the `if let wifiGW` closing brace on line 81) and before the closing brace of the `if status.officeMode != .disabled` block.

- [ ] **Step 2: Build the app target to verify**

Run: `xcodebuild -project macOS/ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnel -configuration Debug build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macOS/ZscalerSplitTunnel/Views/MenuBarView.swift
git commit -m "feat: add device details disclosure group to menu bar"
```

---

## Task 6: Create `NetworkDeviceTab` Settings view

**Files:**
- Create: `macOS/ZscalerSplitTunnel/Views/NetworkDeviceTab.swift`
- Modify: `macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj` (add file to app target)

- [ ] **Step 1: Create the view**

Create `macOS/ZscalerSplitTunnel/Views/NetworkDeviceTab.swift`:

```swift
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
```

- [ ] **Step 2: Add file to Xcode project (app target only)**

Add to `project.pbxproj`:
- PBXFileReference: `E5F6A7B8C9D0E1F2A3B4C5D6`
- PBXBuildFile (app): `F6A7B8C9D0E1F2A3B4C5D6E7`
- Add to Views group

- [ ] **Step 3: Commit**

```bash
git add macOS/ZscalerSplitTunnel/Views/NetworkDeviceTab.swift macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj
git commit -m "feat: add NetworkDeviceTab with full device detail and field toggles"
```

---

## Task 7: Add "Network Device" tab to SettingsView

**Files:**
- Modify: `macOS/ZscalerSplitTunnel/Views/SettingsView.swift:7-26` (add tab)

- [ ] **Step 1: Add the new tab**

In `macOS/ZscalerSplitTunnel/Views/SettingsView.swift`, add the Network Device tab between the Bypass Routes tab and the Advanced tab. After line 19 (the Bypass Routes `ConfigEditorView` closing with `.tabItem`), add:

```swift
NetworkDeviceTab()
    .environment(appState)
    .tabItem { Label("Network Device", systemImage: "wifi.router") }
```

The full `TabView` body becomes:

```swift
TabView {
    GeneralSettingsTab()
        .environment(appState)
        .tabItem { Label("General", systemImage: "gear") }

    ConfigEditorView(configType: .routes)
        .environment(appState)
        .tabItem { Label("Custom Routes", systemImage: "arrow.triangle.branch") }

    ConfigEditorView(configType: .bypass)
        .environment(appState)
        .tabItem { Label("Bypass Routes", systemImage: "arrow.triangle.swap") }

    NetworkDeviceTab()
        .environment(appState)
        .tabItem { Label("Network Device", systemImage: "wifi.router") }

    AdvancedSettingsTab()
        .environment(appState)
        .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
}
.frame(width: 600, height: 400)
```

- [ ] **Step 2: Build full project**

Run: `xcodebuild -project macOS/ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnel -configuration Debug build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macOS/ZscalerSplitTunnel/Views/SettingsView.swift
git commit -m "feat: add Network Device tab to Settings"
```
