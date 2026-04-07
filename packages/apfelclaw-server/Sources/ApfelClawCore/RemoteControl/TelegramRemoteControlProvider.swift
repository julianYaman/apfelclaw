import Foundation

public final class TelegramRemoteControlProvider: @unchecked Sendable {
    static let typingHeartbeatIntervalNanoseconds: UInt64 = 4_000_000_000

    private let remoteControlService: RemoteControlService
    private let commandService: CommandService
    private let conversationService: ConversationService
    private let memoryStore: MemoryStore
    private let debugEnabled: @Sendable () async -> Bool
    private var task: Task<Void, Never>?

    public init(
        remoteControlService: RemoteControlService,
        commandService: CommandService,
        conversationService: ConversationService,
        memoryStore: MemoryStore,
        debugEnabled: @escaping @Sendable () async -> Bool
    ) {
        self.remoteControlService = remoteControlService
        self.commandService = commandService
        self.conversationService = conversationService
        self.memoryStore = memoryStore
        self.debugEnabled = debugEnabled
    }

    public func start() {
        guard task == nil else {
            return
        }

        task = Task {
            await runLoop()
        }
    }

    public func shutdown() {
        task?.cancel()
        task = nil
    }

    private func runLoop() async {
        while Task.isCancelled == false {
            do {
                let config = await remoteControlService.telegramRuntimeConfig()
                guard config.enabled, config.pollingEnabled, config.botToken.isEmpty == false else {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                let updates = try await TelegramRemoteControlAPI.getUpdates(
                    botToken: config.botToken,
                    offset: config.lastUpdateID.map { $0 + 1 },
                    timeout: 20
                )

                for update in updates {
                    try await handle(update: update)
                    try await remoteControlService.setTelegramLastUpdateID(update.updateID)
                }
            } catch is CancellationError {
                return
            } catch {
                if await debugEnabled() {
                    print("[debug][telegram] error=\(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func handle(update: TelegramUpdate) async throws {
        guard let message = update.message,
              let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false,
              let sender = message.from,
              message.chat.type == "private"
        else {
            return
        }

        var config = await remoteControlService.telegramRuntimeConfig()

        if config.approvedChatID == nil {
            guard config.linking else {
                return
            }
            _ = try await remoteControlService.completeTelegramLink(chatID: message.chat.id, userID: sender.id)
            config = await remoteControlService.telegramRuntimeConfig()
        }

        if config.approvedChatID == message.chat.id,
           config.approvedUserID == nil {
            _ = try await remoteControlService.completeTelegramLink(chatID: message.chat.id, userID: sender.id)
            config = await remoteControlService.telegramRuntimeConfig()
        }

        guard config.approvedChatID == message.chat.id,
              config.approvedUserID == sender.id
        else {
            return
        }

        do {
            var sessionID = try sessionID(for: message.chat.id)
            let commandResult = try await commandService.handleIfNeeded(content: text, sessionID: sessionID, source: .telegram)
            if commandResult.handled {
                if let newSessionID = commandResult.sessionID, newSessionID != sessionID {
                    sessionID = newSessionID
                    try memoryStore.upsertRemoteSession(provider: "telegram", remoteID: String(message.chat.id), sessionID: sessionID)
                }
                if let responseText = commandResult.responseText {
                    try await TelegramRemoteControlAPI.sendMessage(
                        botToken: config.botToken,
                        chatID: message.chat.id,
                        text: responseText
                    )
                }
                return
            }

            let typingTask = Self.startTypingHeartbeat(
                botToken: config.botToken,
                chatID: message.chat.id,
                debugEnabled: debugEnabled
            )
            defer { typingTask.cancel() }

            let response = try await conversationService.sendMessage(
                sessionID: sessionID,
                userInput: text,
                autoApproveTools: config.autoApproveTools
            )
            try await TelegramRemoteControlAPI.sendMessage(
                botToken: config.botToken,
                chatID: message.chat.id,
                text: response.assistantMessage
            )
        } catch let error as AppError {
            try await TelegramRemoteControlAPI.sendMessage(
                botToken: config.botToken,
                chatID: message.chat.id,
                text: error.localizedDescription
            )
        }
    }

    static func startTypingHeartbeat(
        botToken: String,
        chatID: Int64,
        intervalNanoseconds: UInt64 = typingHeartbeatIntervalNanoseconds,
        debugEnabled: @escaping @Sendable () async -> Bool,
        sendChatAction: @escaping @Sendable (_ botToken: String, _ chatID: Int64) async throws -> Void = { botToken, chatID in
            try await TelegramRemoteControlAPI.sendChatAction(botToken: botToken, chatID: chatID, action: "typing")
        }
    ) -> Task<Void, Never> {
        Task {
            while Task.isCancelled == false {
                do {
                    try await sendChatAction(botToken, chatID)
                } catch is CancellationError {
                    return
                } catch {
                    if await debugEnabled() {
                        print("[debug][telegram] typing_error=\(error.localizedDescription)")
                    }
                }

                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func sessionID(for chatID: Int64) throws -> Int64 {
        if let existing = try memoryStore.remoteSessionID(provider: "telegram", remoteID: String(chatID)) {
            return existing
        }

        let session = try conversationService.createSession(title: "Telegram Chat \(chatID)")
        try memoryStore.upsertRemoteSession(provider: "telegram", remoteID: String(chatID), sessionID: session.id)
        return session.id
    }
}

enum TelegramRemoteControlAPI {
    static func verifyBot(botToken: String) async throws -> TelegramBotIdentity {
        let response: TelegramAPIEnvelope<TelegramBotResult> = try await request(
            botToken: botToken,
            method: "getMe",
            queryItems: []
        )
        return TelegramBotIdentity(username: response.result.username)
    }

    static func getUpdates(botToken: String, offset: Int64?, timeout: Int) async throws -> [TelegramUpdate] {
        var queryItems = [URLQueryItem(name: "timeout", value: String(timeout))]
        if let offset {
            queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        }

        let response: TelegramAPIEnvelope<[TelegramUpdate]> = try await request(
            botToken: botToken,
            method: "getUpdates",
            queryItems: queryItems
        )
        return response.result
    }

    static func sendMessage(botToken: String, chatID: Int64, text: String) async throws {
        let body = TelegramSendMessageRequest(chatID: chatID, text: text)
        let _: TelegramAPIEnvelope<TelegramSendMessageResult> = try await request(
            botToken: botToken,
            method: "sendMessage",
            queryItems: [],
            body: body
        )
    }

    static func sendChatAction(botToken: String, chatID: Int64, action: String) async throws {
        let body = TelegramSendChatActionRequest(chatID: chatID, action: action)
        let _: TelegramAPIEnvelope<Bool> = try await request(
            botToken: botToken,
            method: "sendChatAction",
            queryItems: [],
            body: body
        )
    }

    private static func request<Response: Decodable, RequestBody: Encodable>(
        botToken: String,
        method: String,
        queryItems: [URLQueryItem],
        body: RequestBody?
    ) async throws -> Response {
        guard var components = URLComponents(string: "https://api.telegram.org/bot\(botToken)/\(method)") else {
            throw AppError.message("Invalid Telegram API URL.")
        }
        if queryItems.isEmpty == false {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw AppError.message("Invalid Telegram API URL.")
        }

        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw AppError.message("Telegram API request failed.")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func request<Response: Decodable>(
        botToken: String,
        method: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        guard var components = URLComponents(string: "https://api.telegram.org/bot\(botToken)/\(method)") else {
            throw AppError.message("Invalid Telegram API URL.")
        }
        if queryItems.isEmpty == false {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw AppError.message("Invalid Telegram API URL.")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw AppError.message("Telegram API request failed.")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct TelegramAPIEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
    let description: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try container.decode(Bool.self, forKey: .ok)
        if ok == false {
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            throw AppError.message(description ?? "Telegram API request failed.")
        }
        self.result = try container.decode(Result.self, forKey: .result)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case result
        case description
    }
}

struct TelegramUpdate: Decodable, Sendable {
    let updateID: Int64
    let message: TelegramMessage?

    private enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }
}

private struct TelegramBotResult: Decodable {
    let username: String
}

struct TelegramMessage: Decodable, Sendable {
    let messageID: Int64
    let from: TelegramUser?
    let chat: TelegramChat
    let text: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case text
    }
}

struct TelegramUser: Decodable, Sendable {
    let id: Int64
}

struct TelegramChat: Decodable, Sendable {
    let id: Int64
    let type: String
}

private struct TelegramSendMessageRequest: Encodable {
    let chatID: Int64
    let text: String

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
    }
}

private struct TelegramSendMessageResult: Decodable {
    let messageID: Int64

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

private struct TelegramSendChatActionRequest: Encodable {
    let chatID: Int64
    let action: String

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case action
    }
}
