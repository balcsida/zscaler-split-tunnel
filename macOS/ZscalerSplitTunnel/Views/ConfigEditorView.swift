import SwiftUI

struct ConfigEditorView: View {
    let configType: ConfigType
    @Environment(AppState.self) private var appState
    @State private var showingAddSheet = false
    @State private var showingRawEditor = false
    @State private var rawText = ""

    private var defaultConfig: ConfigFile {
        configType == .routes ? appState.configService.defaultRoutes : appState.configService.defaultBypass
    }

    private var userConfig: ConfigFile {
        configType == .routes ? appState.configService.userRoutes : appState.configService.userBypass
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(configType == .routes ? "Zscaler Routes" : "Direct Overrides")
                    .font(.headline)
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    showingRawEditor.toggle()
                } label: {
                    Image(systemName: "doc.text")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if showingRawEditor {
                rawEditorSection
            } else {
                listSection
            }
        }
        .onAppear {
            appState.configService.load()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEntrySheet(configType: configType) { text in
                if let entry = ConfigEntry.parse(text) {
                    try? appState.configService.addEntry(entry, to: configType)
                }
            }
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if !defaultConfig.entries.isEmpty {
            Section {
                DisclosureGroup("Default Entries (\(defaultConfig.entries.count))") {
                    List(defaultConfig.entries) { entry in
                        Text(entry.displayString)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
        }

        RoutesListView(
            entries: userConfig.entries,
            configType: configType,
            onRemove: { entry in
                try? appState.configService.removeEntry(entry, from: configType)
            }
        )
    }

    @ViewBuilder
    private var rawEditorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("User Configuration")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .onAppear {
                    let url = configType == .routes ? ConfigPaths.routesConfig : ConfigPaths.bypassConfig
                    rawText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                }

            HStack {
                Spacer()
                Button("Save") {
                    let url = configType == .routes ? ConfigPaths.routesConfig : ConfigPaths.bypassConfig
                    try? rawText.write(to: url, atomically: true, encoding: .utf8)
                    appState.configService.load()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}
