import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            statusSection
            Divider()
            routeSection
            Divider()
            actionSection
            Divider()
            footerSection
        }
        .frame(width: 280)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "shield.checkered")
                .font(.title2)
                .foregroundStyle(stateColor)
            Text("Zscaler Split Tunnel")
                .font(.headline)
            Spacer()
            stateBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var stateBadge: some View {
        Group {
            if let status = appState.helperStatus {
                Text(stateLabel(for: status.splitTunnelState))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.15))
                    .foregroundStyle(stateColor)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 6) {
            if let status = appState.helperStatus {
                StatusRow(icon: "network", label: "Interface",
                          value: status.zscalerInterface ?? "None",
                          valueColor: status.zscalerInterface != nil ? .primary : .secondary)

                StatusRow(icon: "app.badge.checkmark", label: "Zscaler",
                          value: status.zscalerRunning ? "Running" : "Stopped",
                          valueColor: status.zscalerRunning ? .green : .red)

                StatusRow(icon: "timer", label: "Monitoring",
                          value: status.isMonitoring ? "Active (\(status.monitorInterval)s)" : "Off",
                          valueColor: status.isMonitoring ? .green : .secondary)

                if status.officeMode != .disabled {
                    StatusRow(icon: "building.2", label: "Office Mode",
                              value: officeModeLabel(status.officeMode),
                              valueColor: officeModeColor(status.officeMode))

                    if let switchName = status.officeSwitchName {
                        StatusRow(icon: "wifi.router", label: "Switch",
                                  value: switchName)
                    }

                    if let wifiGW = status.officeWifiGateway {
                        StatusRow(icon: "wifi", label: "WiFi GW",
                                  value: wifiGW)
                    }
                }

                if let device = status.discoveredDevice {
                    ForEach(DeviceField.allCases.filter {
                        appState.deviceFieldPreferences.isEnabled($0)
                    }, id: \.self) { field in
                        if let fieldValue = field.value(from: device) {
                            StatusRow(icon: field.icon, label: field.label,
                                      value: fieldValue)
                        }
                    }
                }

                if let lastRefresh = status.lastRefresh {
                    StatusRow(icon: "clock.arrow.circlepath", label: "Last Refresh",
                              valueView: AnyView(Text(lastRefresh, style: .relative)
                                .foregroundStyle(.secondary)))
                }
            } else if let error = appState.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if !appState.isHelperInstalled {
                    MenuButton(title: "Install Helper", icon: "arrow.down.circle") {
                        appState.installHelper()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting...")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Routes

    private var routeSection: some View {
        VStack(spacing: 4) {
            if let status = appState.helperStatus {
                HStack(spacing: 12) {
                    RouteCounter(label: "Custom", count: status.customRouteCount, icon: "arrow.triangle.branch")
                    RouteCounter(label: "Bypass", count: status.bypassRouteCount, icon: "arrow.uturn.right")
                    broadRouteIndicator(status.broadRoutesPresent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func broadRouteIndicator(_ broad: HelperStatus.BroadRouteStatus) -> some View {
        let total = broad.ipv4Present + broad.ipv6Present
        let isClean = total == 0
        return VStack(spacing: 2) {
            Image(systemName: isClean ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isClean ? .green : .red)
            Text("Broad")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(isClean ? "Clear" : "\(total)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(isClean ? .green : .red)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var actionSection: some View {
        VStack(spacing: 2) {
            if appState.helperStatus?.isMonitoring == true {
                MenuButton(title: "Stop Monitoring", icon: "stop.circle") {
                    appState.stopMonitoring()
                }
            } else {
                MenuButton(title: "Start Monitoring", icon: "play.circle") {
                    appState.startMonitoring()
                }
            }

            MenuButton(title: "Refresh Now", icon: "arrow.clockwise",
                       disabled: appState.isLoading) {
                appState.refreshNow()
            }

            Divider()
                .padding(.vertical, 2)

            if appState.helperStatus?.zscalerRunning == true {
                MenuButton(title: "Kill Zscaler", icon: "xmark.circle", role: .destructive) {
                    appState.killZscaler()
                }
            } else {
                MenuButton(title: "Start Zscaler", icon: "play.fill") {
                    appState.startZscaler()
                }
            }

            MenuButton(title: "Flush DNS Cache", icon: "arrow.triangle.2.circlepath") {
                appState.flushDNS()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gear")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var stateColor: Color {
        guard let status = appState.helperStatus else { return .secondary }
        switch status.splitTunnelState {
        case .active: return .green
        case .partial: return .orange
        case .inactive: return .red
        case .unknown: return .secondary
        }
    }

    private func stateLabel(for state: SplitTunnelState) -> String {
        switch state {
        case .active: return "Active"
        case .partial: return "Partial"
        case .inactive: return "Inactive"
        case .unknown: return "Unknown"
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

// MARK: - Components

private struct StatusRow: View {
    let icon: String
    let label: String
    var value: String = ""
    var valueColor: Color = .primary
    var valueView: AnyView?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let valueView {
                valueView
                    .font(.callout)
            } else {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(valueColor)
            }
        }
    }
}

private struct RouteCounter: View {
    let label: String
    let count: Int
    let icon: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.callout.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MenuButton: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16, alignment: .center)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuItemButtonStyle())
        .disabled(disabled)
    }
}

private struct MenuItemButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.2) : .clear)
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
