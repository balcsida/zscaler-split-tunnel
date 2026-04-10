# Network Device Info — Design Spec

Expose the full CDP/LLDP discovered device data through the XPC interface and display it in the UI with a compact menu bar summary and a detailed Settings tab.

## Context

The helper daemon already captures rich device data via CDP and LLDP parsers (`DiscoveredDevice` struct), but only `officeSwitchName: String?` is passed to the frontend via `HelperStatus`. Users cannot see port, VLAN, platform, capabilities, or other debug information.

## Data Layer

### DTO-based approach (`DiscoveredDeviceInfo`)

Instead of moving `DiscoveredDevice` to Shared, a separate `DiscoveredDeviceInfo` Codable DTO lives in `Shared/DiscoveredDeviceInfo.swift`. The helper-side `DiscoveredDevice` stays in `ZscalerSplitTunnelHelper/Discovery/` and provides a `toInfo()` method that converts to the DTO for XPC transport. This keeps the helper's mutable model (with `merge()`, `seenProtocols`, etc.) separate from the serialization boundary.

### Extend `HelperStatus`

Add a new optional field to `HelperStatus`:

```swift
var discoveredDevice: DiscoveredDeviceInfo?
```

The DTO serializes inside the existing `getStatus()` JSON round-trip. No new XPC methods needed.

### Update `HelperTool.getStatus()`

Populate `discoveredDevice` from `monitorLoop.lastDiscoveredDevice?.toInfo()` via a synchronized `statusSnapshot()` call on MonitorLoop's queue. The `officeSwitchName` field is tracked separately and only updates when a device matches the configured office switch patterns.

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
| `Shared/DiscoveredDeviceInfo.swift` | New — Codable DTO for XPC transport |
| `Shared/XPCTypes.swift` | Add `discoveredDevice: DiscoveredDeviceInfo?` to `HelperStatus` |
| `Shared/DeviceField.swift` | New — enum with cases, labels, icons |
| `ZscalerSplitTunnelHelper/Discovery/DiscoveredDevice.swift` | Add `toInfo()` conversion to DTO |
| `ZscalerSplitTunnelHelper/HelperTool.swift` | Populate `discoveredDevice` via `statusSnapshot()` |
| `ZscalerSplitTunnelHelper/MonitorLoop.swift` | Add `statusSnapshot()`, serialize state mutations onto queue |
| `ZscalerSplitTunnel/Views/MenuBarView.swift` | Add `DisclosureGroup` for device summary |
| `ZscalerSplitTunnel/Views/SettingsView.swift` | Add "Network Device" tab |
| `ZscalerSplitTunnel/Views/NetworkDeviceTab.swift` | New — full device detail + field toggles |
| `ZscalerSplitTunnel/ViewModels/DeviceFieldPreferences.swift` | New — UserDefaults wrapper for field visibility |
