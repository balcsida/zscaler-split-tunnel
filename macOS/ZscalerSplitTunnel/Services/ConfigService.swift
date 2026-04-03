import Foundation
import Observation

enum ConfigType: Sendable {
    case routes
    case bypass
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
        switch config {
        case .routes:
            userRoutes.append(entry)
            try userRoutes.write(to: ConfigPaths.routesConfig)
        case .bypass:
            userBypass.append(entry)
            try userBypass.write(to: ConfigPaths.bypassConfig)
        }
    }

    func removeEntry(_ entry: ConfigEntry, from config: ConfigType) throws {
        switch config {
        case .routes:
            userRoutes.remove(entry)
            try userRoutes.write(to: ConfigPaths.routesConfig)
        case .bypass:
            userBypass.remove(entry)
            try userBypass.write(to: ConfigPaths.bypassConfig)
        }
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
