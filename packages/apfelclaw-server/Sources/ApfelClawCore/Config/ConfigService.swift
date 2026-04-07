import Foundation

public actor ConfigService {
    public static let maxNameLength = 80

    private let settingsStore: SettingsStore
    private var config: AppConfig

    public init(settingsStore: SettingsStore, defaults: AppConfig = .default) throws {
        self.settingsStore = settingsStore

        if let stored = try settingsStore.load() {
            self.config = stored
        } else {
            self.config = defaults
            try settingsStore.save(defaults)
        }
    }

    public var configPath: URL {
        settingsStore.configURL
    }

    public func current() -> EditableAppConfig {
        EditableAppConfig(config: config)
    }

    public func currentAppConfig() -> AppConfig {
        config
    }

    public func update(_ update: EditableAppConfigUpdate) throws -> EditableAppConfig {
        var next = config

        if let assistantName = update.assistantName {
            next.assistantName = try validateName(assistantName, field: "assistantName")
        }

        if let userName = update.userName {
            next.userName = try validateName(userName, field: "userName")
        }

        if let approvalMode = update.approvalMode {
            next.approvalMode = try validateApprovalMode(approvalMode)
        }
        if let debug = update.debug {
            next.debug = debug
        }

        try settingsStore.save(next)
        config = next
        return EditableAppConfig(config: next)
    }

    private func validateName(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else {
            throw AppError.message("'\(field)' cannot be empty.")
        }

        guard trimmed.count <= Self.maxNameLength else {
            throw AppError.message("'\(field)' must be \(Self.maxNameLength) characters or less.")
        }

        return trimmed
    }

    private func validateApprovalMode(_ value: String) throws -> ApprovalMode {
        guard let mode = ApprovalMode(rawValue: value) else {
            let supported = ApprovalMode.allCases.map(\.rawValue).joined(separator: ", ")
            throw AppError.message("Invalid approvalMode '\(value)'. Supported values: \(supported).")
        }
        return mode
    }
}
