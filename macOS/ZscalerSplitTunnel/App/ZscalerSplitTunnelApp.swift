import SwiftUI

@main
struct ZscalerSplitTunnelApp: App {
    @State private var appState = AppState()

    init() {
        try? ConfigPaths.ensureUserConfigDir()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }

    var menuBarIcon: String {
        switch appState.splitTunnelState {
        case .active: return "shield.checkered"
        case .partial: return "shield.lefthalf.filled"
        case .inactive: return "shield.slash"
        case .unknown: return "shield"
        }
    }
}
