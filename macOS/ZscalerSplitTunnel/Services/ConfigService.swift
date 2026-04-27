import Foundation
import Observation

enum ConfigType: Sendable {
    case routes
    case bypass
}

struct OfficeModeConfigDTO: Codable, Equatable, Sendable {
    var enabled: Bool
    var targetSSID: String
    var cdpGracePeriodSeconds: Int
    var switchNamePatterns: [String]

    static let `default` = OfficeModeConfigDTO(
        enabled: false,
        targetSSID: "",
        cdpGracePeriodSeconds: 120,
        switchNamePatterns: []
    )
}

@Observable
final class ConfigService {
    var defaultRoutes = ConfigFile()
    var userRoutes = ConfigFile()
    var defaultBypass = ConfigFile()
    var userBypass = ConfigFile()

    private var watchSources: [DispatchSourceFileSystemObject] = []
    private var watchDescriptors: [Int32] = []

    func load() {
        if let url = ConfigPaths.defaultRoutesConfig {
            defaultRoutes = (try? ConfigFile.parse(contentsOf: url)) ?? ConfigFile()
        }
        if let url = ConfigPaths.defaultBypassConfig {
            defaultBypass = (try? ConfigFile.parse(contentsOf: url)) ?? ConfigFile()
        }

        userRoutes = (try? ConfigFile.parse(contentsOf: ConfigPaths.routesConfig)) ?? ConfigFile()
        userBypass = (try? ConfigFile.parse(contentsOf: ConfigPaths.bypassConfig)) ?? ConfigFile()
    }

    func addEntry(_ entry: ConfigEntry, to config: ConfigType) throws {
        try mutate(config) { $0.append(entry) }
    }

    func removeEntry(_ entry: ConfigEntry, from config: ConfigType) throws {
        try mutate(config) { $0.remove(entry) }
    }

    /// Re-reads the file from disk, applies `change`, then writes back.
    /// Avoids clobbering external edits (or entries added in another window)
    /// that the in-memory snapshot hasn't seen.
    private func mutate(_ config: ConfigType, _ change: (inout ConfigFile) -> Void) throws {
        let path = config == .routes ? ConfigPaths.routesConfig : ConfigPaths.bypassConfig
        var current = (try? ConfigFile.parse(contentsOf: path)) ?? ConfigFile()
        change(&current)
        try current.write(to: path)
        switch config {
        case .routes: userRoutes = current
        case .bypass: userBypass = current
        }
    }

    // MARK: - Office Mode

    func readOfficeMode() -> OfficeModeConfigDTO {
        guard let data = try? Data(contentsOf: ConfigPaths.officeModeConfig),
              let dto = try? JSONDecoder().decode(OfficeModeConfigDTO.self, from: data) else {
            return .default
        }
        return dto
    }

    func writeOfficeMode(_ dto: OfficeModeConfigDTO) throws {
        try ConfigPaths.ensureUserConfigDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dto)
        try data.write(to: ConfigPaths.officeModeConfig, options: .atomic)
    }

    /// Reads the currently associated SSID from the given Wi-Fi interface using `networksetup`.
    func currentSSID(interface: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = ["-getairportnetwork", interface]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        let prefix = "Current Wi-Fi Network: "
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let ssid = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ssid.isEmpty ? nil : ssid
    }

    func startWatching() {
        stopWatching()
        try? ConfigPaths.ensureUserConfigDir()

        let filesToWatch = [
            ConfigPaths.routesConfig,
            ConfigPaths.bypassConfig,
        ]

        for fileURL in filesToWatch {
            let fd = open(fileURL.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            watchDescriptors.append(fd)

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: .main
            )

            source.setEventHandler { [weak self] in
                self?.load()
            }

            source.setCancelHandler {
                close(fd)
            }

            source.resume()
            watchSources.append(source)
        }
    }

    func stopWatching() {
        for source in watchSources {
            source.cancel()
        }
        watchSources.removeAll()
        watchDescriptors.removeAll()
    }
}
