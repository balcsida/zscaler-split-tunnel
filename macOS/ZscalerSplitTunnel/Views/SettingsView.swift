import SwiftUI
import AppKit

/// Renders an SF Symbol to a fixed-size NSImage to prevent macOS from
/// re-rasterizing it on window active/inactive transitions (Apple bug).
private func fixedTabIcon(_ systemName: String, pointSize: CGFloat = 20) -> Image {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    let nsImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    nsImage.isTemplate = true
    return Image(nsImage: nsImage)
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
                .tabItem { Label { Text("Custom Routes") } icon: { fixedTabIcon("arrow.triangle.branch") } }

            ConfigEditorView(configType: .bypass)
                .environment(appState)
                .tabItem { Label { Text("Bypass Routes") } icon: { fixedTabIcon("arrow.triangle.swap") } }

            NetworkDeviceTab()
                .environment(appState)
                .tabItem { Label { Text("Network Device") } icon: { fixedTabIcon("wifi.router") } }

            AdvancedSettingsTab()
                .environment(appState)
                .tabItem { Label { Text("Advanced") } icon: { fixedTabIcon("wrench.and.screwdriver") } }
        }
        .frame(minWidth: 600, minHeight: 400)
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

    var body: some View {
        Form {
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
