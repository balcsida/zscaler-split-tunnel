import SwiftUI

struct StatusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let status = appState.helperStatus {
            LabeledContent("Status") {
                Text(statusText(for: status))
                    .foregroundStyle(statusColor(for: status))
            }

            if let iface = status.zscalerInterface {
                LabeledContent("Interface") {
                    Text(iface)
                }
            }

            LabeledContent("Zscaler") {
                Text(status.zscalerRunning ? "Running" : "Stopped")
                    .foregroundStyle(status.zscalerRunning ? .green : .secondary)
            }

            LabeledContent("Monitoring") {
                Text(status.isMonitoring ? "Active (\(status.monitorInterval)s)" : "Off")
                    .foregroundStyle(status.isMonitoring ? .green : .secondary)
            }

            if status.officeMode != .disabled {
                LabeledContent("Office Mode") {
                    Text(officeModeLabel(status.officeMode))
                        .foregroundStyle(officeModeColor(status.officeMode))
                }

                if let switchName = status.officeSwitchName {
                    LabeledContent("Switch") {
                        Text(switchName)
                    }
                }

                if let wifiGW = status.officeWifiGateway {
                    LabeledContent("WiFi Gateway") {
                        Text(wifiGW)
                    }
                }
            }

            if let lastRefresh = status.lastRefresh {
                LabeledContent("Last Refresh") {
                    Text(lastRefresh, style: .relative)
                }
            }
        } else if let error = appState.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)

            if !appState.isHelperInstalled {
                Button("Install Helper...") { appState.installHelper() }
            }
        } else {
            Text("Connecting...")
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(for status: HelperStatus) -> String {
        switch status.splitTunnelState {
        case .active: return "Active"
        case .partial: return "Partial"
        case .inactive: return "Inactive"
        case .unknown: return "Unknown"
        }
    }

    private func statusColor(for status: HelperStatus) -> Color {
        switch status.splitTunnelState {
        case .active: return .green
        case .partial: return .orange
        case .inactive: return .red
        case .unknown: return .secondary
        }
    }

    private func officeModeLabel(_ mode: OfficeMode) -> String {
        switch mode {
        case .disabled: return "Disabled"
        case .detecting: return "Detecting..."
        case .officeWifi: return "WiFi Routing"
        case .officeNoWifi: return "No WiFi"
        case .notOffice: return "Not in Office"
        }
    }

    private func officeModeColor(_ mode: OfficeMode) -> Color {
        switch mode {
        case .officeWifi: return .green
        case .officeNoWifi: return .orange
        case .detecting: return .secondary
        case .notOffice: return .secondary
        case .disabled: return .secondary
        }
    }
}
