import Foundation

public struct RemoteControlConfig: Codable, Sendable {
    public var telegram: TelegramRemoteControlConfig

    public init(telegram: TelegramRemoteControlConfig = .default) {
        self.telegram = telegram
    }
}

public struct TelegramRemoteControlConfig: Codable, Sendable {
    public var enabled: Bool
    public var pollingEnabled: Bool
    public var autoApproveTools: Bool
    public var botToken: String
    public var botUsername: String
    public var approvedChatID: Int64?
    public var approvedUserID: Int64?
    public var linking: Bool
    public var lastUpdateID: Int64?

    public init(
        enabled: Bool = false,
        pollingEnabled: Bool = false,
        autoApproveTools: Bool = false,
        botToken: String = "",
        botUsername: String = "",
        approvedChatID: Int64? = nil,
        approvedUserID: Int64? = nil,
        linking: Bool = false,
        lastUpdateID: Int64? = nil
    ) {
        self.enabled = enabled
        self.pollingEnabled = pollingEnabled
        self.autoApproveTools = autoApproveTools
        self.botToken = botToken
        self.botUsername = botUsername
        self.approvedChatID = approvedChatID
        self.approvedUserID = approvedUserID
        self.linking = linking
        self.lastUpdateID = lastUpdateID
    }
}

public struct TelegramRemoteControlStatus: Codable, Sendable {
    public let enabled: Bool
    public let pollingEnabled: Bool
    public let autoApproveTools: Bool
    public let hasBotToken: Bool
    public let botUsername: String?
    public let approvedChatID: Int64?
    public let approvedUserID: Int64?
    public let linking: Bool

    public init(
        enabled: Bool,
        pollingEnabled: Bool,
        autoApproveTools: Bool,
        hasBotToken: Bool,
        botUsername: String?,
        approvedChatID: Int64?,
        approvedUserID: Int64?,
        linking: Bool
    ) {
        self.enabled = enabled
        self.pollingEnabled = pollingEnabled
        self.autoApproveTools = autoApproveTools
        self.hasBotToken = hasBotToken
        self.botUsername = botUsername
        self.approvedChatID = approvedChatID
        self.approvedUserID = approvedUserID
        self.linking = linking
    }
}

public struct RemoteControlStatus: Codable, Sendable {
    public let telegram: TelegramRemoteControlStatus

    public init(telegram: TelegramRemoteControlStatus) {
        self.telegram = telegram
    }
}

public struct TelegramRemoteControlSetupRequest: Codable, Sendable {
    public let botToken: String

    public init(botToken: String) {
        self.botToken = botToken
    }
}

public struct TelegramBotIdentity: Sendable {
    public let username: String

    public init(username: String) {
        self.username = username
    }
}

public extension RemoteControlConfig {
    static let `default` = RemoteControlConfig()
}

public extension TelegramRemoteControlConfig {
    static let `default` = TelegramRemoteControlConfig()
}
