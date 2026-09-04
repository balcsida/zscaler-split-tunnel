import Foundation

enum ProxySettings {
    static func endpoint(
        configURL: URL,
        isReachable: (String, Int) -> Bool
    ) -> URL? {
        guard let settings = load(configURL: configURL),
              let host = settings.endpoint.host,
              isReachable(host, settings.endpoint.port ?? 80) else {
            return nil
        }
        return settings.endpoint
    }

    static func refreshEnvironment(
        configURL: URL,
        environmentURL: URL,
        isReachable: (String, Int) -> Bool = probe
    ) {
        guard let settings = load(configURL: configURL),
              let host = settings.endpoint.host,
              isReachable(host, settings.endpoint.port ?? 80) else {
            try? FileManager.default.removeItem(at: environmentURL)
            return
        }

        let endpoint = shellQuote(settings.endpoint.absoluteString)
        let noProxy = shellQuote(settings.noProxy)
        let contents = """
        export HTTP_PROXY=\(endpoint)
        export HTTPS_PROXY=\(endpoint)
        export http_proxy=\(endpoint)
        export https_proxy=\(endpoint)
        export NO_PROXY=\(noProxy)
        export no_proxy=\(noProxy)

        """

        do {
            try FileManager.default.createDirectory(
                at: environmentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: environmentURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: environmentURL)
        }
    }

    private static func load(configURL: URL) -> (endpoint: URL, noProxy: String)? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        let lines = contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let noProxyPrefix = "no_proxy="
        let noProxy = lines.first(where: { $0.hasPrefix(noProxyPrefix) })
            .map { String($0.dropFirst(noProxyPrefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "localhost,127.0.0.1"
        guard let value = lines.first(where: { !$0.hasPrefix(noProxyPrefix) }),
              let endpoint = URL(string: value),
              endpoint.scheme == "http",
              endpoint.host != nil else {
            return nil
        }
        return (endpoint, noProxy)
    }

    private static func probe(host: String, port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-w1", host, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
