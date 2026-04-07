import Foundation

public enum ApprovalMode: String, Codable, CaseIterable, Sendable {
    case always
    case askOncePerToolPerSession = "ask-once-per-tool-per-session"
    case trustedReadonly = "trusted-readonly"

    public var label: String {
        switch self {
        case .always:
            return "Always ask"
        case .askOncePerToolPerSession:
            return "Ask once per tool per session"
        case .trustedReadonly:
            return "Trusted read-only"
        }
    }
}

public struct AppConfig: Codable, Sendable {
    public var assistantName: String
    public var userName: String
    public var approvalMode: ApprovalMode
    public var debug: Bool
    public var memoryEnabled: Bool
    public var defaultCalendarScope: String
    public var terminalToolsEnabled: Bool
    public var apfelAutostartEnabled: Bool

    public init(
        assistantName: String,
        userName: String,
        approvalMode: ApprovalMode,
        debug: Bool = false,
        memoryEnabled: Bool,
        defaultCalendarScope: String = "all-visible",
        terminalToolsEnabled: Bool = true,
        apfelAutostartEnabled: Bool = true
    ) {
        self.assistantName = assistantName
        self.userName = userName
        self.approvalMode = approvalMode
        self.debug = debug
        self.memoryEnabled = memoryEnabled
        self.defaultCalendarScope = defaultCalendarScope
        self.terminalToolsEnabled = terminalToolsEnabled
        self.apfelAutostartEnabled = apfelAutostartEnabled
    }

    enum CodingKeys: String, CodingKey {
        case assistantName
        case userName
        case approvalMode
        case debug
        case memoryEnabled
        case defaultCalendarScope
        case terminalToolsEnabled
        case apfelAutostartEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.assistantName = try container.decode(String.self, forKey: .assistantName)
        self.userName = try container.decode(String.self, forKey: .userName)
        self.approvalMode = try container.decode(ApprovalMode.self, forKey: .approvalMode)
        self.debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        self.memoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        self.defaultCalendarScope = try container.decodeIfPresent(String.self, forKey: .defaultCalendarScope) ?? "all-visible"
        self.terminalToolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminalToolsEnabled) ?? true
        self.apfelAutostartEnabled = try container.decodeIfPresent(Bool.self, forKey: .apfelAutostartEnabled) ?? true
    }
}

public struct EditableAppConfig: Codable, Equatable, Sendable {
    public var assistantName: String
    public var userName: String
    public var approvalMode: String
    public var debug: Bool

    public init(
        assistantName: String,
        userName: String,
        approvalMode: String,
        debug: Bool
    ) {
        self.assistantName = assistantName
        self.userName = userName
        self.approvalMode = approvalMode
        self.debug = debug
    }

    public init(config: AppConfig) {
        self.init(
            assistantName: config.assistantName,
            userName: config.userName,
            approvalMode: config.approvalMode.rawValue,
            debug: config.debug
        )
    }
}

public struct EditableAppConfigUpdate: Codable, Equatable, Sendable {
    public var assistantName: String?
    public var userName: String?
    public var approvalMode: String?
    public var debug: Bool?

    public init(
        assistantName: String? = nil,
        userName: String? = nil,
        approvalMode: String? = nil,
        debug: Bool? = nil
    ) {
        self.assistantName = assistantName
        self.userName = userName
        self.approvalMode = approvalMode
        self.debug = debug
    }
}

public extension AppConfig {
    static let `default` = AppConfig(
        assistantName: "Apfelclaw",
        userName: "You",
        approvalMode: .trustedReadonly,
        memoryEnabled: true
    )
}
