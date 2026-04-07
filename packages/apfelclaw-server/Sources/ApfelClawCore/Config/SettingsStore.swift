import Foundation

public final class SettingsStore: Sendable {
    public let configURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directories: AppDirectories) {
        self.configURL = directories.configRoot.appendingPathComponent("config.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> AppConfig? {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: configURL)
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }
}
