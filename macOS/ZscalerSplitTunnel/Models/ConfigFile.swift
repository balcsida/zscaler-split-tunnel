import Foundation

struct ConfigFile: Sendable {
    var lines: [ConfigLine]

    enum ConfigLine: Sendable, Identifiable {
        case comment(String)
        case blank
        case entry(ConfigEntry)

        var id: String {
            switch self {
            case .comment(let text): return "comment:\(text)"
            case .blank: return "blank:\(UUID().uuidString)"
            case .entry(let entry): return "entry:\(entry.displayString)"
            }
        }
    }

    init(lines: [ConfigLine] = []) {
        self.lines = lines
    }

    var entries: [ConfigEntry] {
        lines.compactMap {
            if case .entry(let entry) = $0 { return entry }
            return nil
        }
    }

    mutating func append(_ entry: ConfigEntry) {
        lines.append(.entry(entry))
    }

    mutating func remove(_ entry: ConfigEntry) {
        lines.removeAll { line in
            if case .entry(let existing) = line {
                return existing == entry
            }
            return false
        }
    }

    static func parse(contentsOf url: URL) throws -> ConfigFile {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(string: content)
    }

    static func parse(string content: String) -> ConfigFile {
        let rawLines = content.components(separatedBy: .newlines)
        var configLines: [ConfigLine] = []

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                configLines.append(.blank)
            } else if trimmed.hasPrefix("#") {
                configLines.append(.comment(rawLine))
            } else if let entry = ConfigEntry.parse(trimmed) {
                configLines.append(.entry(entry))
            } else {
                // Preserve unrecognised lines as comments
                configLines.append(.comment(rawLine))
            }
        }

        return ConfigFile(lines: configLines)
    }

    func write(to url: URL) throws {
        let content = lines.map { line -> String in
            switch line {
            case .comment(let text): return text
            case .blank: return ""
            case .entry(let entry): return entry.displayString
            }
        }.joined(separator: "\n")

        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
