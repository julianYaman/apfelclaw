import Foundation

public struct SessionMessage: Codable, Sendable {
    public let role: String
    public let content: String
}

public struct ToolExecutionSummary: Codable, Sendable {
    public let name: String
    public let argumentsJSON: String
    public let approved: Bool
}

public struct ConversationTurnResponse: Codable, Sendable {
    public let sessionID: Int64
    public let assistantMessage: String
    public let toolCall: ToolExecutionSummary?
}

public final class ConversationService: @unchecked Sendable {
    private let memoryStore: MemoryStore
    private let configService: ConfigService
    private let modelClient: any ModelCompleting
    private let toolRuntime: ToolRuntime
    private let eventHub: SessionEventHub?
    private let apfelMaintenanceService: ApfelMaintenanceService?

    public init(
        memoryStore: MemoryStore,
        configService: ConfigService,
        modelClient: any ModelCompleting,
        toolRuntime: ToolRuntime,
        eventHub: SessionEventHub? = nil,
        apfelMaintenanceService: ApfelMaintenanceService? = nil
    ) {
        self.memoryStore = memoryStore
        self.configService = configService
        self.modelClient = modelClient
        self.toolRuntime = toolRuntime
        self.eventHub = eventHub
        self.apfelMaintenanceService = apfelMaintenanceService
    }

    public func createSession(title: String? = nil) throws -> SessionRecord {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Session \(ISO8601DateFormatter().string(from: Date()))"
        let id = try memoryStore.createSession(title: resolvedTitle)
        return SessionRecord(id: id, title: resolvedTitle, createdAt: ISO8601DateFormatter().string(from: Date()))
    }

    public func listSessions(limit: Int = 20) throws -> [SessionRecord] {
        try memoryStore.listSessions(limit: limit)
    }

    public func listMessages(sessionID: Int64, limit: Int = 100) throws -> [SessionMessage] {
        try memoryStore.listMessages(sessionID: sessionID, limit: limit).map {
            SessionMessage(role: $0.role, content: $0.content)
        }
    }

    public func sendMessage(sessionID: Int64, userInput: String, autoApproveTools: Bool) async throws -> ConversationTurnResponse {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw AppError.message("Message content cannot be empty.")
        }

        try await apfelMaintenanceService?.ensureAvailable()

        let config = await configService.currentAppConfig()
        let toolPolicy = ToolPolicy(approvalMode: config.approvalMode)
        let requestTime = Date()
        let requestTimeZone = TimeZone.current

        try memoryStore.appendMessage(sessionID: sessionID, role: "user", content: trimmed)
        eventHub?.publish(
            StreamEvent(
                type: "message.created",
                sessionID: sessionID,
                message: SessionMessage(role: "user", content: trimmed)
            )
        )

        let recentMessages = try memoryStore.listMessages(sessionID: sessionID, limit: 20)
        let sessionSummary = config.memoryEnabled ? try memoryStore.latestSummary(sessionID: sessionID) : nil
        let lastToolCall = try memoryStore.latestToolCall(sessionID: sessionID)
        let intentRouterDebugLog: (@Sendable (String) -> Void)? = config.debug ? { @Sendable (message: String) in
            print(message)
        } : nil
        let routing = try await IntentRouter.route(
            messages: recentMessages,
            userInput: trimmed,
            sessionSummary: sessionSummary,
            lastToolCall: lastToolCall,
            toolRegistry: toolRuntime.registry,
            modelClient: modelClient,
            referenceDate: requestTime,
            timeZone: requestTimeZone,
            debugLog: intentRouterDebugLog
        )
        if config.debug {
            let renderedTool = routing.toolName ?? "(none)"
            let debugTrace = routing.debugTrace ?? "null"
            print("[debug][intent_router] input=\"\(trimmed)\" action=\(routing.action.rawValue) tool=\(renderedTool) reason_code=\(routing.reasonCode.rawValue) trace=\(debugTrace)")
        }

        if routing.action == .useTool,
           let toolName = routing.toolName,
           let selectedTool = toolRuntime.definition(named: toolName) {
            let toolMessages = buildToolCallPrompt(
                from: recentMessages,
                config: config,
                sessionSummary: sessionSummary,
                selectedTool: selectedTool,
                now: requestTime,
                timeZone: requestTimeZone
            )
            let outcome = try await modelClient.complete(messages: toolMessages, tools: [selectedTool], mode: .toolAware)

            if let toolCall = validatedToolCall(outcome.toolCall, selectedToolName: toolName) {
                return try await executeToolRoundTrip(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    priorMessages: toolMessages,
                    toolPolicy: toolPolicy,
                    debugEnabled: config.debug,
                    userInput: trimmed,
                    autoApproveTools: autoApproveTools,
                    memoryEnabled: config.memoryEnabled,
                    requestTime: requestTime,
                    requestTimeZone: requestTimeZone
                )
            }

            if let fallbackToolCall = toolRuntime.deterministicFallbackToolCall(named: toolName) {
                if config.debug {
                    print("[debug][tool_call_fallback] name=\(toolName) reason=no_valid_tool_call")
                }
                return try await executeToolRoundTrip(
                    sessionID: sessionID,
                    toolCall: fallbackToolCall,
                    priorMessages: toolMessages,
                    toolPolicy: toolPolicy,
                    debugEnabled: config.debug,
                    userInput: trimmed,
                    autoApproveTools: autoApproveTools,
                    memoryEnabled: config.memoryEnabled,
                    requestTime: requestTime,
                    requestTimeZone: requestTimeZone
                )
            }

            if let text = outcome.text {
                try persistAssistantMessage(sessionID: sessionID, content: text, memoryEnabled: config.memoryEnabled)
                return ConversationTurnResponse(sessionID: sessionID, assistantMessage: text, toolCall: nil)
            }

            throw AppError.message("The selected tool step returned neither a valid tool call nor clarification text.")
        }

        if routing.action == .clarify {
            let clarification = Self.clarificationMessage()
            try persistAssistantMessage(sessionID: sessionID, content: clarification, memoryEnabled: config.memoryEnabled)
            return ConversationTurnResponse(sessionID: sessionID, assistantMessage: clarification, toolCall: nil)
        }

        let promptMessages = buildChatPrompt(
            from: recentMessages,
            config: config,
            sessionSummary: sessionSummary,
            now: requestTime,
            timeZone: requestTimeZone
        )
        let outcome = try await modelClient.complete(messages: promptMessages, tools: [], mode: .userFacingText)
        if let text = outcome.text {
            try persistAssistantMessage(sessionID: sessionID, content: text, memoryEnabled: config.memoryEnabled)
            return ConversationTurnResponse(sessionID: sessionID, assistantMessage: text, toolCall: nil)
        }

        throw AppError.message("No text or tool call was returned.")
    }

    private func executeToolRoundTrip(
        sessionID: Int64,
        toolCall: ToolCall,
        priorMessages: [ChatMessage],
        toolPolicy: ToolPolicy,
        debugEnabled: Bool,
        userInput: String,
        autoApproveTools: Bool,
        memoryEnabled: Bool,
        requestTime: Date,
        requestTimeZone: TimeZone
    ) async throws -> ConversationTurnResponse {
        let selectedTool = toolRuntime.definition(named: toolCall.name)
        let priorApprovalExists = try memoryStore.hasApprovedToolCall(sessionID: sessionID, toolName: toolCall.name)
        let approved = autoApproveTools || {
            guard let selectedTool else {
                return false
            }
            return toolPolicy.requiresPrompt(for: selectedTool, priorApprovalExists: priorApprovalExists) == false
        }()
        let summary = ToolExecutionSummary(name: toolCall.name, argumentsJSON: toolCall.argumentsJSON, approved: approved)
        if debugEnabled {
            print("[debug][tool_call] name=\(toolCall.name) approved=\(approved) arguments=\(toolCall.argumentsJSON)")
        }
        eventHub?.publish(
            StreamEvent(type: "tool.called", sessionID: sessionID, toolCall: summary)
        )

        guard approved else {
            let deniedPayload = #"{"arguments":"\#(escapeForJSON(toolCall.argumentsJSON))","result":"Tool use denied."}"#
            try memoryStore.logToolCall(
                sessionID: sessionID,
                toolName: toolCall.name,
                approved: false,
                payload: deniedPayload
            )
            let toolLabel = selectedTool?.summary ?? toolCall.name
            let assistantMessage = "I needed to use \(toolLabel) to answer that, but tool approval was not granted. If you want, enable tool approval and ask again."
            try persistAssistantMessage(sessionID: sessionID, content: assistantMessage, memoryEnabled: memoryEnabled)
            return ConversationTurnResponse(sessionID: sessionID, assistantMessage: assistantMessage, toolCall: summary)
        }

        let toolResult: String
        do {
            toolResult = try await toolRuntime.execute(
                toolCall: toolCall,
                userInput: userInput,
                context: ToolExecutionContext(referenceDate: requestTime, timeZone: requestTimeZone)
            )
        } catch {
            let toolLabel = selectedTool?.summary ?? toolCall.name
            let assistantMessage = "I tried to use \(toolLabel), but it failed: \(error.localizedDescription). Please try again or rephrase the request."
            try persistAssistantMessage(sessionID: sessionID, content: assistantMessage, memoryEnabled: memoryEnabled)
            return ConversationTurnResponse(sessionID: sessionID, assistantMessage: assistantMessage, toolCall: summary)
        }

        let logPayload = #"{"arguments":"\#(escapeForJSON(toolCall.argumentsJSON))","result":"\#(escapeForJSON(toolResult))"}"#
        try memoryStore.logToolCall(
            sessionID: sessionID,
            toolName: toolCall.name,
            approved: true,
            payload: logPayload
        )
        if debugEnabled {
            print("[debug][tool_result] name=\(toolCall.name) output=\(toolResult)")
        }

        let assistantMessage: String
        if let tool = selectedTool,
           let module = toolRuntime.module(named: tool.name),
           let formatted = module.summarizeResult(
                 toolResult,
                 context: ToolPresentationContext(referenceDate: requestTime, timeZone: requestTimeZone)
            ) {
            assistantMessage = formatted
        } else {
            let assistantToolMessage = ChatMessage(
                role: "assistant",
                content: nil,
                toolCalls: [
                    ChatToolCall(
                        id: toolCall.id,
                        type: "function",
                        function: .init(name: toolCall.name, arguments: toolCall.argumentsJSON)
                    )
                ]
            )
            let toolMessage = ChatMessage(
                role: "tool",
                content: toolResult,
                name: toolCall.name,
                toolCallID: toolCall.id
            )
            let followUp = ChatMessage(
                role: "user",
                content: """
                Summarize the tool result for the user in a concise answer. If the result is empty, say that clearly.
                Make sure that data like dates are human-readable and in the timezone of the user.
                """
            )

            let messages = priorMessages + [assistantToolMessage, toolMessage, followUp]
            let outcome = try await modelClient.complete(messages: messages, tools: [], mode: .userFacingText)
            guard let text = outcome.text else {
                throw AppError.message("The tool result summary did not return text.")
            }
            assistantMessage = text
        }

        try persistAssistantMessage(sessionID: sessionID, content: assistantMessage, memoryEnabled: memoryEnabled)
        return ConversationTurnResponse(sessionID: sessionID, assistantMessage: assistantMessage, toolCall: summary)
    }

    private func buildChatPrompt(
        from messages: [(role: String, content: String)],
        config: AppConfig,
        sessionSummary: String?,
        now: Date,
        timeZone: TimeZone
    ) -> [ChatMessage] {
        let systemPrompt = Self.systemPrompt(
            assistantName: config.assistantName,
            userName: config.userName,
            now: now,
            timeZone: timeZone
        )

        var promptMessages: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
        if let sessionSummary = sessionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), sessionSummary.isEmpty == false {
            promptMessages.append(ChatMessage(role: "system", content: "Session summary:\n\(sessionSummary)"))
        }
        promptMessages.append(contentsOf: messages.map { ChatMessage(role: $0.role, content: $0.content) })
        return promptMessages
    }

    private func buildToolCallPrompt(
        from messages: [(role: String, content: String)],
        config: AppConfig,
        sessionSummary: String?,
        selectedTool: ToolDefinition,
        now: Date,
        timeZone: TimeZone
    ) -> [ChatMessage] {
        let systemPrompt = Self.toolCallSystemPrompt(
            assistantName: config.assistantName,
            userName: config.userName,
            selectedTool: selectedTool,
            now: now,
            timeZone: timeZone
        )

        var promptMessages: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
        if let sessionSummary = sessionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), sessionSummary.isEmpty == false {
            promptMessages.append(ChatMessage(role: "system", content: "Session summary:\n\(sessionSummary)"))
        }
        promptMessages.append(contentsOf: messages.map { ChatMessage(role: $0.role, content: $0.content) })
        return promptMessages
    }

    static func systemPrompt(
        assistantName: String,
        userName: String,
        now: Date,
        timeZone: TimeZone
    ) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone

        let humanFormatter = DateFormatter()
        humanFormatter.locale = Locale(identifier: "en_US_POSIX")
        humanFormatter.timeZone = timeZone
        humanFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm:ss zzz"

        return """
        You are \(assistantName), a local macOS assistant running inside apfelclaw.
        The user's preferred name is \(userName).
        Backend version: \(AppVersion.current).
        Keep answers concise and practical.
        Reference time for this request: \(humanFormatter.string(from: now)) (\(isoFormatter.string(from: now))).
        Treat that reference time and timezone as the source of truth for "today", "tomorrow", and other relative time phrases.
        Make sure that data like dates are always human-readable and in the timezone of the user.
        Do not guess personal, local, or current data. If a reliable answer needs tool-backed lookup, say that clearly instead of inventing details.
        """
    }

    static func toolCallSystemPrompt(
        assistantName: String,
        userName: String,
        selectedTool: ToolDefinition,
        now: Date,
        timeZone: TimeZone
    ) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone

        let humanFormatter = DateFormatter()
        humanFormatter.locale = Locale(identifier: "en_US_POSIX")
        humanFormatter.timeZone = timeZone
        humanFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm:ss zzz"

        let allowedKeys = selectedTool.parameters.objectValue?["properties"]?.objectValue?.keys.sorted().joined(separator: ", ") ?? "(none)"

        return """
        You are \(assistantName), a local macOS assistant running inside apfelclaw.
        The user's preferred name is \(userName).
        The router already selected the tool "\(selectedTool.name)" for this turn.
        Your job is to call exactly that tool using only its documented argument keys.
        Allowed argument keys for this tool: \(allowedKeys).
        If required information is missing, ask one short clarification question instead of inventing arguments.
        Never choose a different tool name.
        Never answer from memory when the selected tool should be used.
        Never write JSON, code fences, or pseudo-tool-call payloads to represent tool use.
        If you call a tool, call exactly one tool.
        Reference time for this request: \(humanFormatter.string(from: now)) (\(isoFormatter.string(from: now))).
        Treat that reference time and timezone as the source of truth for "today", "tomorrow", and other relative time phrases.
        Selected tool summary: \(selectedTool.summary)
        Selected tool description: \(selectedTool.description)
        """
    }

    private func validatedToolCall(_ toolCall: ToolCall?, selectedToolName: String) -> ToolCall? {
        guard let toolCall, toolCall.name == selectedToolName else {
            return nil
        }
        return toolCall
    }

    private func persistAssistantMessage(sessionID: Int64, content: String, memoryEnabled: Bool) throws {
        try memoryStore.appendMessage(sessionID: sessionID, role: "assistant", content: content)
        eventHub?.publish(
            StreamEvent(
                type: "message.created",
                sessionID: sessionID,
                message: SessionMessage(role: "assistant", content: content)
            )
        )

        guard memoryEnabled else {
            return
        }

        try refreshSessionSummary(sessionID: sessionID)
    }

    private func refreshSessionSummary(sessionID: Int64) throws {
        let messages = try memoryStore.listMessages(sessionID: sessionID, limit: 200)
        guard let summary = summarizedHistory(from: messages) else {
            try memoryStore.deleteSessionSummary(sessionID: sessionID)
            return
        }
        try memoryStore.replaceSessionSummary(sessionID: sessionID, summary: summary)
    }

    private func summarizedHistory(from messages: [(role: String, content: String)]) -> String? {
        let recentWindow = 12
        guard messages.count > recentWindow else {
            return nil
        }

        let olderMessages = Array(messages.dropLast(recentWindow))
        let sample = olderMessages.suffix(8)
        var lines: [String] = []
        var remaining = 1_200

        for message in sample {
            let normalized = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else {
                continue
            }

            let capped = String(normalized.prefix(180))
            let line = "\(message.role): \(capped)"
            guard line.count <= remaining else {
                break
            }
            lines.append(line)
            remaining -= line.count
        }

        guard lines.isEmpty == false else {
            return nil
        }

        return "Earlier context:\n" + lines.joined(separator: "\n")
    }

    private static func clarificationMessage() -> String {
        "I need a bit more detail to answer that reliably. If you want live data from this Mac, tell me what to check, such as your calendar, recent mail, files, or Mac status."
    }

    private func escapeForJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
