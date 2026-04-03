import SwiftUI

struct RoutesListView: View {
    let entries: [ConfigEntry]
    let configType: ConfigType
    let onRemove: (ConfigEntry) -> Void

    @State private var showingAddSheet = false

    var body: some View {
        VStack {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Entries",
                    systemImage: configType == .routes ? "arrow.triangle.branch" : "arrow.triangle.swap",
                    description: Text("Add entries to configure \(configType == .routes ? "custom routes" : "bypass routes").")
                )
            } else {
                Table(entries, columns: {
                    TableColumn("Entry") { entry in
                        Text(entry.displayString)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Type", value: \.typeLabel)
                        .width(80)
                    TableColumn("") { entry in
                        Button(role: .destructive) {
                            onRemove(entry)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(30)
                })
            }
        }
    }
}

extension ConfigEntry: Identifiable {
    public var id: String { displayString }
}

extension ConfigEntry {
    var typeLabel: String {
        switch self {
        case .domain: return "Domain"
        case .ip: return "IP"
        case .cidr: return "CIDR"
        case .url: return "URL"
        case .wildcard: return "Wildcard"
        }
    }
}
