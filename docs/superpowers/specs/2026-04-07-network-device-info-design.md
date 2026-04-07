# Network Device Info — Design Spec

Expose the full CDP/LLDP discovered device data through the XPC interface and display it in the UI with a compact menu bar summary and a detailed Settings tab.

## Context

The helper daemon already captures rich device data via CDP and LLDP parsers (`DiscoveredDevice` struct), but only `officeSwitchName: String?` is passed to the frontend via `HelperStatus`. Users cannot see port, VLAN, platform, capabilities, or other debug information.

## Data Layer

### Move `DiscoveredDevice` to Shared

Move `DiscoveredDevice.swift` (containing `DiscoveredDevice`, `DiscoveryProtocol`, `OrganizationalTLV`) from `ZscalerSplitTunnelHelper/Discovery/` to `Shared/`. Add `Codable` and `Sendable` conformance to all three types. Remove the `Identifiable` conformance and `id` stored properties (UUID doesn't round-trip well over JSON; the frontend can add its own identity if needed for SwiftUI lists).

### Extend `HelperStatus`

Add a new optional field to `HelperStatus`:

```swift
var discoveredDevice: DiscoveredDevice?
```

Since `DiscoveredDevice` is now `Codable` and in `Shared/`, it serializes directly inside the existing `getStatus()` JSON round-trip. No new XPC methods needed.

### Update `HelperTool.getStatus()`

Populate `discoveredDevice` from `monitorLoop.officeDetector.lastDiscoveredDevice`. The existing `officeSwitchName` field remains for backwards compatibility (it's used by the existing office mode UI).

## Menu Bar — Expandable Device Summary

### Location

Inside the `officeMode != .disabled` block in `MenuBarView.statusSection`, below the existing "Switch" and "WiFi GW" rows.

### Behavior

- **Visibility:** Only shown when `helperStatus.discoveredDevice != nil` (hidden when empty — keeps menu bar compact).
- **Component:** SwiftUI `DisclosureGroup` with header label "Device Details".
- **Content:** `StatusRow` entries for each field enabled by the user.
- **Default state:** Collapsed.

### Configurable Fields

An enum `DeviceField` with cases:

| Case | Label | Icon | Source |
|------|-------|------|--------|
| `portId` | Port | `cable.connector` | `discoveredDevice.portId` |
| `nativeVlan` | VLAN | `number` | `discoveredDevice.nativeVlan` (formatted as string) |
| `platform` | Platform | `cpu` | `discoveredDevice.platform` |
| `protocolType` | Protocol | `antenna.radiowaves.left.and.right` | `discoveredDevice.protocolType.rawValue` |
| `managementIP` | Mgmt IP | `network` | `discoveredDevice.managementAddresses.first` |
| `sourceInterface` | Interface | `rectangle.connected.to.line.below` | `discoveredDevice.sourceInterface` |
| `duplex` | Duplex | `arrow.left.arrow.right` | `discoveredDevice.duplex` |

Default enabled set: `portId`, `nativeVlan`, `platform`.

## Settings — Network Device Tab

### Tab

New tab in `SettingsView` titled "Network Device" with SF Symbol `wifi.router`. Positioned between "Bypass Routes" and "Advanced".

### Discovered Device Section

A `Form` section titled "Discovered Device" showing all fields when data is available:

- Device ID, System Name, Protocol Type, Source Interface, Source MAC
- Port ID, Port Description, Native VLAN, Duplex
- Platform, Software Version, VTP Domain, Power Available
- Capabilities (comma-separated)
- Management Addresses (one row each)
- Chassis ID, TTL
- Organizational TLVs (displayed as "OUI / Subtype: value" per row)
- Discovery timestamp (relative time, matching the "Last Refresh" style)

**Empty state:** "No device discovered" with subtitle "Connect via Ethernet to detect network switches via CDP/LLDP".

### Menu Bar Fields Section

A section titled "Menu Bar Fields" with 7 `Toggle` rows, one per `DeviceField` case. Each toggle adds/removes the field from the visible set. Bound to `UserDefaults`.

## Storage

### User Preferences (App-side)

- **Key:** `menuBarDeviceFields`
- **Value:** `[String]` — array of `DeviceField` raw values
- **Default:** `["portId", "nativeVlan", "platform"]`
- **Storage:** `UserDefaults.standard`

Managed via an `@AppStorage` or a small preferences helper in the app target. No config files — this is a UI-only display preference.

### No Helper-side Config Changes

The helper already collects `DiscoveredDevice`. The only helper change is including it in the `HelperStatus` JSON response.

## File Changes Summary

| File | Change |
|------|--------|
| `Shared/DiscoveredDevice.swift` | New — moved from helper, add Codable/Sendable |
| `Shared/XPCTypes.swift` | Add `discoveredDevice: DiscoveredDevice?` to `HelperStatus` |
| `Shared/DeviceField.swift` | New — enum with cases, labels, icons |
| `ZscalerSplitTunnelHelper/Discovery/DiscoveredDevice.swift` | Remove (moved to Shared) |
| `ZscalerSplitTunnelHelper/HelperTool.swift` | Populate `discoveredDevice` in `getStatus()` |
| `ZscalerSplitTunnel/Views/MenuBarView.swift` | Add `DisclosureGroup` for device summary |
| `ZscalerSplitTunnel/Views/SettingsView.swift` | Add "Network Device" tab |
| `ZscalerSplitTunnel/Views/NetworkDeviceTab.swift` | New — full device detail + field toggles |
| `ZscalerSplitTunnel/ViewModels/DeviceFieldPreferences.swift` | New — UserDefaults wrapper for field visibility |
