import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
        .frame(minWidth: 600, minHeight: 400)
        .symbolRenderingMode(.monochrome)
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
