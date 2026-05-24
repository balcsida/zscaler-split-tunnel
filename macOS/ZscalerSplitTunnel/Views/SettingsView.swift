import SwiftUI
import AppKit

/// Renders an SF Symbol to a fixed-size NSImage to prevent macOS from
/// re-rasterizing it on window active/inactive transitions (Apple bug).
/// Rasterizes an SF Symbol into a fixed-size bitmap so macOS cannot
/// re-rasterize or stretch it on window state changes.
private func fixedTabIcon(_ systemName: String, canvasSize: CGFloat = 24) -> Image {
    let config = NSImage.SymbolConfiguration(pointSize: canvasSize * 0.75, weight: .regular)
    guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil),
          let symbol = base.withSymbolConfiguration(config) else {
        return Image(systemName: systemName)
    }

    let canvas = NSSize(width: canvasSize, height: canvasSize)
    let result = NSImage(size: canvas, flipped: false) { rect in
        let symbolSize = symbol.size
        let x = (rect.width - symbolSize.width) / 2
        let y = (rect.height - symbolSize.height) / 2
        symbol.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
        return true
    }
    result.isTemplate = true
    return Image(nsImage: result)
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environment(appState)
                .tabItem { Label { Text("General") } icon: { fixedTabIcon("gear") } }

            ConfigEditorView(configType: .routes)
                .environment(appState)
                .tabItem { Label { Text("Zscaler Routes") } icon: { fixedTabIcon("arrow.triangle.branch") } }

            ConfigEditorView(configType: .bypass)
                .environment(appState)
                .tabItem { Label { Text("Direct Overrides") } icon: { fixedTabIcon("arrow.triangle.swap") } }

            NetworkDeviceTab()
                .environment(appState)
                .tabItem { Label { Text("Network Device") } icon: { fixedTabIcon("wifi.router") } }

            OfficeModeTab()
                .environment(appState)
                .tabItem { Label { Text("Office Mode") } icon: { fixedTabIcon("building.2") } }

            AdvancedSettingsTab()
                .environment(appState)
                .tabItem { Label { Text("Advanced") } icon: { fixedTabIcon("wrench.and.screwdriver") } }
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
    }
}

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Helper Tool") {
                LabeledContent("Status") {
                    Text(appState.isHelperInstalled ? "Installed" : "Not Installed")
                        .foregroundStyle(appState.isHelperInstalled ? .green : .red)
                }

                if let version = appState.helperStatus?.version {
                    LabeledContent("Version") {
                        Text(version)
                    }
                }

                Button("Reinstall Helper") {
                    appState.installHelper()
                }
                .disabled(appState.isLoading)
            }

            Section("Monitoring") {
                LabeledContent("Status") {
                    Text(appState.helperStatus?.isMonitoring == true ? "Active" : "Inactive")
                }

                if let interval = appState.helperStatus?.monitorInterval {
                    LabeledContent("Interval") {
                        Text("\(interval) seconds")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("Recovery") {
                Text("If split tunneling leaves the routing table wedged (sites like claude.ai fail with ERR_ADDRESS_INVALID), this stops Zscaler and monitoring, clears stale tunnel routes, flushes the routing table, and refreshes IPv6 on active services. IPv4 connectivity stays up; IPv6 drops for about a second.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Reset Routes & Recover Connectivity") {
                    showResetConfirm = true
                }
                .disabled(appState.isLoading)
                .confirmationDialog(
                    "This will stop Zscaler, flush all routes, and refresh IPv6 on active network services. IPv4 stays up; IPv6 will blink briefly.",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset Now", role: .destructive) { appState.recoverConnectivity() }
                    Button("Cancel", role: .cancel) {}
                }
            }

            Section("Autostart") {
                HStack {
                    Button("Enable Autostart") {
                        Task {
                            try? await appState.helperConnection.enableAutostart()
                        }
                    }
                    Button("Disable Autostart") {
                        Task {
                            try? await appState.helperConnection.disableAutostart()
                        }
                    }
                }
            }

            Section("Broad Routes") {
                if let broad = appState.helperStatus?.broadRoutesPresent {
                    LabeledContent("IPv4") {
                        Text("\(broad.ipv4Present) / \(broad.ipv4Total) present")
                    }
                    LabeledContent("IPv6") {
                        Text("\(broad.ipv6Present) / \(broad.ipv6Total) present")
                    }
                }

                Button("Remove Broad Routes") {
                    Task {
                        _ = try? await appState.helperConnection.removeBroadRoutes()
                    }
                }
            }

            Section("Network") {
                if let sig = appState.helperStatus?.networkSignature {
                    LabeledContent("Network Signature") {
                        Text(sig)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
