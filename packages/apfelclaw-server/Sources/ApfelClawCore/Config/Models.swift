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
    public var apfelHost: String?
    public var apfelPort: Int?

    public init(
        assistantName: String,
        userName: String,
        approvalMode: ApprovalMode,
        debug: Bool = false,
        memoryEnabled: Bool,
        defaultCalendarScope: String = "all-visible",
        terminalToolsEnabled: Bool = true,
        apfelAutostartEnabled: Bool = true,
        apfelHost: String? = nil,
        apfelPort: Int? = nil
    ) {
        self.assistantName = assistantName
        self.userName = userName
        self.approvalMode = approvalMode
        self.debug = debug
        self.memoryEnabled = memoryEnabled
        self.defaultCalendarScope = defaultCalendarScope
        self.terminalToolsEnabled = terminalToolsEnabled
        self.apfelAutostartEnabled = apfelAutostartEnabled
        self.apfelHost = apfelHost
        self.apfelPort = apfelPort
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
        case apfelHost
        case apfelPort
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
        self.apfelHost = try container.decodeIfPresent(String.self, forKey: .apfelHost)
        self.apfelPort = try container.decodeIfPresent(Int.self, forKey: .apfelPort)
    }
}

public struct EditableAppConfig: Codable, Equatable, Sendable {
    public var assistantName: String
    public var userName: String
    public var approvalMode: String
    public var debug: Bool
    public var apfelHost: String
    public var apfelPort: Int

    public init(
        assistantName: String,
        userName: String,
        approvalMode: String,
        debug: Bool,
        apfelHost: String,
        apfelPort: Int
    ) {
        self.assistantName = assistantName
        self.userName = userName
        self.approvalMode = approvalMode
        self.debug = debug
        self.apfelHost = apfelHost
        self.apfelPort = apfelPort
    }

    public init(config: AppConfig) {
        let endpoint = ApfelEndpoint.resolve(config: config)
        self.init(
            assistantName: config.assistantName,
            userName: config.userName,
            approvalMode: config.approvalMode.rawValue,
            debug: config.debug,
            apfelHost: endpoint.host,
            apfelPort: endpoint.port
        )
    }
}

public struct EditableAppConfigUpdate: Codable, Equatable, Sendable {
    public var assistantName: String?
    public var userName: String?
    public var approvalMode: String?
    public var debug: Bool?
    public var apfelHost: String?
    public var apfelPort: Int?

    public init(
        assistantName: String? = nil,
        userName: String? = nil,
        approvalMode: String? = nil,
        debug: Bool? = nil,
        apfelHost: String? = nil,
        apfelPort: Int? = nil
    ) {
        self.assistantName = assistantName
        self.userName = userName
        self.approvalMode = approvalMode
        self.debug = debug
        self.apfelHost = apfelHost
        self.apfelPort = apfelPort
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
