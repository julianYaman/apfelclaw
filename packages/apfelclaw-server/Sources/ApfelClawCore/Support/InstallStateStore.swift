import Foundation

public enum AppInstallSource: String, Codable, Sendable {
    case homebrew
    case manual
    case unknown
}

public struct InstallState: Codable, Sendable {
    public var schemaVersion: Int
    public var onboardingCompletedAt: String?
    public var installSource: AppInstallSource
    public var lastRunVersion: String?

    public init(
        schemaVersion: Int = 1,
        onboardingCompletedAt: String? = nil,
        installSource: AppInstallSource = .unknown,
        lastRunVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.onboardingCompletedAt = onboardingCompletedAt
        self.installSource = installSource
        self.lastRunVersion = lastRunVersion
    }

    public var onboardingCompleted: Bool {
        onboardingCompletedAt != nil
    }
}

public final class InstallStateStore {
    public let stateURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directories: AppDirectories) {
        self.stateURL = directories.stateURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> InstallState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: stateURL)
        return try decoder.decode(InstallState.self, from: data)
    }

    @discardableResult
    public func current(defaultInstallSource: AppInstallSource = .unknown) throws -> InstallState {
        try load() ?? InstallState(installSource: defaultInstallSource)
    }

    public func save(_ state: InstallState) throws {
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    @discardableResult
    public func markOnboardingCompleted(installSource: AppInstallSource) throws -> InstallState {
        var state = try current(defaultInstallSource: installSource)
        state.installSource = installSource
        state.lastRunVersion = AppVersion.current
        state.onboardingCompletedAt = ISO8601DateFormatter().string(from: Date())
        try save(state)
        return state
    }

    @discardableResult
    public func refreshRuntimeState(installSource: AppInstallSource) throws -> InstallState {
        var state = try current(defaultInstallSource: installSource)
        state.installSource = installSource
        state.lastRunVersion = AppVersion.current
        try save(state)
        return state
    }
}
