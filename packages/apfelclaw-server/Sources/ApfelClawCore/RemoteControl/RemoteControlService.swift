import Foundation

public actor RemoteControlService {
    private let settingsStore: RemoteControlSettingsStore
    private let verifyTelegramBot: @Sendable (String) async throws -> TelegramBotIdentity
    private var config: RemoteControlConfig

    public init(
        settingsStore: RemoteControlSettingsStore,
        defaults: RemoteControlConfig = .default,
        verifyTelegramBot: (@Sendable (String) async throws -> TelegramBotIdentity)? = nil
    ) throws {
        self.settingsStore = settingsStore
        self.verifyTelegramBot = verifyTelegramBot ?? TelegramRemoteControlAPI.verifyBot

        if let stored = try settingsStore.load() {
            self.config = stored
        } else {
            self.config = defaults
            try settingsStore.save(defaults)
        }
    }

    public func current() -> RemoteControlStatus {
        RemoteControlStatus(telegram: telegramStatus(from: config.telegram))
    }

    public func telegramStatus() -> TelegramRemoteControlStatus {
        telegramStatus(from: config.telegram)
    }

    public func telegramRuntimeConfig() -> TelegramRemoteControlConfig {
        config.telegram
    }

    public func setupTelegram(botToken: String) async throws -> TelegramRemoteControlStatus {
        let trimmed = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw AppError.message("Telegram bot token cannot be empty.")
        }

        let identity = try await verifyTelegramBot(trimmed)
        config.telegram = TelegramRemoteControlConfig(
            enabled: true,
            pollingEnabled: true,
            autoApproveTools: false,
            botToken: trimmed,
            botUsername: identity.username,
            approvedChatID: nil,
            approvedUserID: nil,
            linking: true,
            lastUpdateID: nil
        )
        try settingsStore.save(config)
        return telegramStatus(from: config.telegram)
    }

    public func disableTelegram() throws -> TelegramRemoteControlStatus {
        config.telegram.enabled = false
        config.telegram.pollingEnabled = false
        config.telegram.linking = false
        try settingsStore.save(config)
        return telegramStatus(from: config.telegram)
    }

    public func resetTelegram() throws -> TelegramRemoteControlStatus {
        config.telegram = .default
        try settingsStore.save(config)
        return telegramStatus(from: config.telegram)
    }

    public func completeTelegramLink(chatID: Int64, userID: Int64) throws -> TelegramRemoteControlStatus {
        config.telegram.enabled = true
        config.telegram.pollingEnabled = true
        config.telegram.approvedChatID = chatID
        config.telegram.approvedUserID = userID
        config.telegram.linking = false
        try settingsStore.save(config)
        return telegramStatus(from: config.telegram)
    }

    public func setTelegramLastUpdateID(_ updateID: Int64) throws {
        guard config.telegram.lastUpdateID != updateID else {
            return
        }
        config.telegram.lastUpdateID = updateID
        try settingsStore.save(config)
    }

    private func telegramStatus(from config: TelegramRemoteControlConfig) -> TelegramRemoteControlStatus {
        TelegramRemoteControlStatus(
            enabled: config.enabled,
            pollingEnabled: config.pollingEnabled,
            autoApproveTools: config.autoApproveTools,
            hasBotToken: config.botToken.isEmpty == false,
            botUsername: config.botUsername.isEmpty ? nil : config.botUsername,
            approvedChatID: config.approvedChatID,
            approvedUserID: config.approvedUserID,
            linking: config.linking
        )
    }
}
