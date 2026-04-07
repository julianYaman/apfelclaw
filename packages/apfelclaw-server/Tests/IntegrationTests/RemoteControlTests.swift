import Foundation
import Testing
@testable import ApfelClawCore

@Test
func remoteControlServicePersistsVerifiedTelegramSetup() async throws {
    let harness = try RemoteControlTestHarness()
    let service = try harness.makeRemoteControlService { token in
        #expect(token == "123:abc")
        return TelegramBotIdentity(username: "apfelclaw_bot")
    }

    let status = try await service.setupTelegram(botToken: " 123:abc ")

    #expect(status.enabled == true)
    #expect(status.pollingEnabled == true)
    #expect(status.hasBotToken == true)
    #expect(status.botUsername == "apfelclaw_bot")
    #expect(status.approvedUserID == nil)
    #expect(status.linking == true)

    let reloaded = try harness.makeRemoteControlService { _ in
        Issue.record("Verifier should not run when loading persisted remote control config.")
        return TelegramBotIdentity(username: "unused")
    }
    let reloadedStatus = await reloaded.telegramStatus()

    #expect(reloadedStatus.enabled == true)
    #expect(reloadedStatus.botUsername == "apfelclaw_bot")
    #expect(reloadedStatus.approvedUserID == nil)
    #expect(reloadedStatus.linking == true)
}

@Test
func remoteControlServiceStoresApprovedTelegramUserIDOnLink() async throws {
    let harness = try RemoteControlTestHarness()
    let service = try harness.makeRemoteControlService { _ in
        TelegramBotIdentity(username: "apfelclaw_bot")
    }

    _ = try await service.setupTelegram(botToken: "123:abc")
    let status = try await service.completeTelegramLink(chatID: 42, userID: 99)

    #expect(status.approvedChatID == 42)
    #expect(status.approvedUserID == 99)
    #expect(status.linking == false)
}

@Test
func commandServiceCreatesNewSessionForRemoteNewCommand() async throws {
    let harness = try RemoteControlTestHarness()
    let configService = try harness.makeConfigService()
    let conversationService = try harness.makeConversationService(configService: configService)
    let commandService = CommandService(configService: configService, conversationService: conversationService)
    let initialSession = try conversationService.createSession(title: "Initial")

    let result = try await commandService.handleIfNeeded(content: "/new", sessionID: initialSession.id, source: .telegram)

    #expect(result.handled == true)
    #expect(result.sessionID != initialSession.id)
    #expect(result.responseText?.contains("Started a new session") == true)
    #expect(try conversationService.listSessions().count == 2)
}

@Test
func commandServiceUpdatesConfigFromRemoteCommand() async throws {
    let harness = try RemoteControlTestHarness()
    let configService = try harness.makeConfigService()
    let conversationService = try harness.makeConversationService(configService: configService)
    let commandService = CommandService(configService: configService, conversationService: conversationService)
    let session = try conversationService.createSession(title: "Initial")

    let result = try await commandService.handleIfNeeded(
        content: "/config set assistantName Orbit",
        sessionID: session.id,
        source: .telegram
    )

    #expect(result.handled == true)
    #expect(result.responseText?.contains("assistantName: Orbit") == true)
    #expect(await configService.current().assistantName == "Orbit")
}

@Test
func memoryStorePersistsRemoteSessionMappings() throws {
    let harness = try RemoteControlTestHarness()
    let session = try harness.memoryStore.createSession(title: "Telegram")

    try harness.memoryStore.upsertRemoteSession(provider: "telegram", remoteID: "42", sessionID: session)

    #expect(try harness.memoryStore.remoteSessionID(provider: "telegram", remoteID: "42") == session)
}

private struct RemoteControlTestHarness {
    let root: URL
    let directories: AppDirectories
    let settingsStore: SettingsStore
    let remoteControlSettingsStore: RemoteControlSettingsStore
    let memoryStore: MemoryStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.directories = try AppDirectories(homeDirectory: root)
        try directories.bootstrap()
        self.settingsStore = SettingsStore(directories: directories)
        self.remoteControlSettingsStore = RemoteControlSettingsStore(directories: directories)
        self.memoryStore = MemoryStore(directories: directories)
        try memoryStore.open()
    }

    func makeConfigService(defaults: AppConfig = .default) throws -> ConfigService {
        try ConfigService(settingsStore: settingsStore, defaults: defaults)
    }

    func makeRemoteControlService(
        verify: @escaping @Sendable (String) async throws -> TelegramBotIdentity
    ) throws -> RemoteControlService {
        try RemoteControlService(settingsStore: remoteControlSettingsStore, verifyTelegramBot: verify)
    }

    func makeConversationService(configService: ConfigService) throws -> ConversationService {
        try ConversationService(
            memoryStore: memoryStore,
            configService: configService,
            modelClient: CommandTestModelClient(),
            toolRuntime: ToolRuntime()
        )
    }
}

private struct CommandTestModelClient: ModelCompleting {
    func complete(messages: [ChatMessage], tools: [ToolDefinition], mode: CompletionMode) async throws -> CompletionOutcome {
        CompletionOutcome(text: "", toolCall: nil)
    }
}
