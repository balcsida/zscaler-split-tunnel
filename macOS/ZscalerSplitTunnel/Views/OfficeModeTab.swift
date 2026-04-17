import SwiftUI

struct OfficeModeTab: View {
    @Environment(AppState.self) private var appState

    @State private var form: OfficeModeConfigDTO = .default
    @State private var loadedSnapshot: OfficeModeConfigDTO = .default
    @State private var saveError: String?
    @State private var didLoad = false

    private var isDirty: Bool { form != loadedSnapshot }

    private var saveDisabled: Bool {
        if !isDirty { return true }
        if form.enabled && form.trimmedSSID.isEmpty { return true }
        return false
    }

    var body: some View {
        Form {
            statusSection
            configSection
            patternsSection

            if let err = saveError {
                Section {
                    Text(err).foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Revert") { form = loadedSnapshot; saveError = nil }
                        .disabled(!isDirty)
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(saveDisabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !didLoad else { return }
            let dto = appState.configService.readOfficeMode()
            form = dto
            loadedSnapshot = dto
            didLoad = true
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Mode") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(modeColor)
                        .frame(width: 8, height: 8)
                    Text(modeLabel)
                }
            }
            LabeledContent("Detected Switch") {
                Text(appState.helperStatus?.officeSwitchName ?? "—")
                    .textSelection(.enabled)
            }
            LabeledContent("WiFi Gateway") {
                Text(appState.helperStatus?.officeWifiGateway ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("WiFi Interface") {
                Text(appState.helperStatus?.captureStatus?.wifiInterface ?? "—")
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private var modeLabel: String {
        switch appState.helperStatus?.officeMode ?? .disabled {
        case .disabled: return "Disabled"
        case .detecting: return "Detecting…"
        case .officeWifi: return "Office (WiFi routing active)"
        case .officeNoWifi: return "Office (no matching WiFi)"
        case .notOffice: return "Not in office"
        }
    }

    private var modeColor: Color {
        switch appState.helperStatus?.officeMode ?? .disabled {
        case .disabled, .notOffice: return .gray
        case .detecting: return .yellow
        case .officeWifi: return .green
        case .officeNoWifi: return .orange
        }
    }

    // MARK: - Config

    @ViewBuilder
    private var configSection: some View {
        Section("Configuration") {
            Toggle("Enable Office Mode", isOn: Binding(
                get: { form.enabled },
                set: { form.enabled = $0 }
            ))

            HStack {
                TextField("Target SSID", text: Binding(
                    get: { form.targetSSID },
                    set: { form.targetSSID = $0 }
                ))
                Button("Use current") {
                    fillCurrentSSID()
                }
                .disabled(appState.helperStatus?.captureStatus?.wifiInterface == nil)
            }

            Stepper(value: Binding(
                get: { form.cdpGracePeriodSeconds },
                set: { form.cdpGracePeriodSeconds = $0 }
            ), in: 30...600, step: 10) {
                Text("Grace period: \(form.cdpGracePeriodSeconds) s")
            }

            if form.enabled && form.trimmedSSID.isEmpty {
                Text("Target SSID is required when Office Mode is enabled.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Patterns

    @ViewBuilder
    private var patternsSection: some View {
        Section {
            ForEach(form.switchNamePatterns.indices, id: \.self) { idx in
                HStack {
                    TextField("*-corp-sw*", text: Binding(
                        get: { form.switchNamePatterns[idx] },
                        set: { form.switchNamePatterns[idx] = $0 }
                    ))
                    Button(role: .destructive) {
                        form.switchNamePatterns.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }

            Button {
                form.switchNamePatterns.append("")
            } label: {
                Label("Add pattern", systemImage: "plus.circle")
            }
        } header: {
            Text("Switch Name Patterns")
        } footer: {
            Text("Optional. Use `*` as a prefix or suffix wildcard (e.g. `*-corp-sw*`). Empty list matches any switch discovered via CDP/LLDP.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func fillCurrentSSID() {
        guard let iface = appState.helperStatus?.captureStatus?.wifiInterface else { return }
        if let ssid = appState.configService.currentSSID(interface: iface) {
            form.targetSSID = ssid
        }
    }

    private func save() {
        var dto = form
        dto.targetSSID = dto.trimmedSSID
        dto.switchNamePatterns = dto.switchNamePatterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            try appState.configService.writeOfficeMode(dto)
            form = dto
            loadedSnapshot = dto
            saveError = nil
            appState.refreshNow()
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }
}

private extension OfficeModeConfigDTO {
    var trimmedSSID: String {
        targetSSID.trimmingCharacters(in: .whitespaces)
    }
}
