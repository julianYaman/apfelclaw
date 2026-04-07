import Foundation

public struct AppDirectories {
    public let home: URL
    public let configRoot: URL
    public let cacheRoot: URL
    public let logsRoot: URL
    public let sessionRoot: URL

    public init(fileManager: FileManager = .default) throws {
        guard let homeDirectory = fileManager.homeDirectoryForCurrentUser as URL? else {
            throw AppError.message("Unable to locate the home directory.")
        }

        try self.init(homeDirectory: homeDirectory)
    }

    public init(homeDirectory: URL) throws {
        self.home = homeDirectory
        self.configRoot = homeDirectory.appendingPathComponent(".apfelclaw", isDirectory: true)
        self.cacheRoot = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("apfelclaw", isDirectory: true)
        self.logsRoot = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("apfelclaw", isDirectory: true)
        self.sessionRoot = configRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    public func bootstrap(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
    }
}
