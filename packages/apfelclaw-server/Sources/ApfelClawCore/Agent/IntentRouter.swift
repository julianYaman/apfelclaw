import Foundation

public enum RoutingAction: String, Codable, Sendable {
    case useTool = "use_tool"
    case answerDirectly = "answer_directly"
    case clarify = "clarify"
}

public enum RoutingReasonCode: String, Codable, Sendable {
    case freshPersonalData = "fresh_personal_data"
    case sameDomainFollowUp = "same_domain_follow_up"
    case priorResultInsufficient = "prior_result_insufficient"
    case directAnswerOK = "direct_answer_ok"
    case other = "other"
}

public struct RoutingDecision: Sendable {
    public let action: RoutingAction
    public let toolName: String?
    public let reasonCode: RoutingReasonCode
    public let debugTrace: String?

    public init(action: RoutingAction, toolName: String?, reasonCode: RoutingReasonCode, debugTrace: String? = nil) {
        self.action = action
        self.toolName = toolName
        self.reasonCode = reasonCode
        self.debugTrace = debugTrace
    }
}

private struct ToolIntentSelection: Codable, Equatable {
    let action: RoutingAction
    let toolName: String?
    let reasonCode: RoutingReasonCode
}

private struct RawToolIntentSelection: Codable {
    let action: String
    let toolName: String?
    let reasonCode: String
}

private struct FollowUpReuseSelection: Codable, Equatable {
    let reuseLastTool: Bool
    let reasonCode: RoutingReasonCode
}

private struct RawFollowUpReuseSelection: Codable {
    let reuseLastTool: Bool
    let reasonCode: String
}

private struct LoggedToolPayload: Codable {
    let arguments: String
    let result: String
}

private struct RoutingDebugAttempt: Codable, Sendable {
    let stage: String
    let strict: Bool
    let status: String
    let output: String?
}

private struct RoutingDebugTracePayload: Codable, Sendable {
    let attempts: [RoutingDebugAttempt]
}

private enum RoutingSelectionStatus: Sendable {
    case accepted
    case exhausted
    case modelError
}

public enum IntentRouter {
    public static func route(
        messages: [(role: String, content: String)],
        userInput: String,
        sessionSummary: String?,
        lastToolCall: ToolCallRecord?,
        toolRegistry: ToolRegistry,
        modelClient: any ModelCompleting,
        referenceDate: Date,
        timeZone: TimeZone,
        debugLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> RoutingDecision {
        let (selection, classifierAttempts, classifierStatus) = try await requestClassifierSelection(
            messages: messages,
            userInput: userInput,
            sessionSummary: sessionSummary,
            lastToolCall: lastToolCall,
            toolRegistry: toolRegistry,
            modelClient: modelClient,
            referenceDate: referenceDate,
            timeZone: timeZone,
            debugLog: debugLog
        )
        var debugAttempts = classifierAttempts

        if let selection,
           selection.action == .useTool,
           let toolName = selection.toolName {
            return RoutingDecision(action: .useTool, toolName: toolName, reasonCode: selection.reasonCode, debugTrace: renderDebugTrace(debugAttempts))
        }

        if classifierStatus == .modelError {
            return RoutingDecision(action: .clarify, toolName: nil, reasonCode: .other, debugTrace: renderDebugTrace(debugAttempts))
        }

        let (recovered, followUpAttempts, followUpStatus) = try await recoverToolFromFollowUpReuse(
            initialSelection: selection,
            messages: messages,
            userInput: userInput,
            sessionSummary: sessionSummary,
            lastToolCall: lastToolCall,
            toolRegistry: toolRegistry,
            modelClient: modelClient,
            referenceDate: referenceDate,
            timeZone: timeZone,
            debugLog: debugLog
        )
        debugAttempts.append(contentsOf: followUpAttempts)
        let finalDebugTrace = renderDebugTrace(debugAttempts)

        if let recovered {
            return RoutingDecision(
                action: recovered.action,
                toolName: recovered.toolName,
                reasonCode: recovered.reasonCode,
                debugTrace: finalDebugTrace
            )
        }

        if selection == nil {
            return RoutingDecision(
                action: .clarify,
                toolName: nil,
                reasonCode: .other,
                debugTrace: finalDebugTrace
            )
        }

        if let selection,
           selection.action == .answerDirectly {
            return RoutingDecision(
                action: .answerDirectly,
                toolName: nil,
                reasonCode: selection.reasonCode,
                debugTrace: finalDebugTrace
            )
        }

        if followUpStatus == .modelError {
            return RoutingDecision(action: .clarify, toolName: nil, reasonCode: .other, debugTrace: finalDebugTrace)
        }

        return RoutingDecision(action: .clarify, toolName: nil, reasonCode: .other, debugTrace: finalDebugTrace)
    }

    static func buildClassifierMessages(
        messages: [(role: String, content: String)],
        userInput: String,
        sessionSummary: String?,
        lastToolCall: ToolCallRecord?,
        toolRegistry: ToolRegistry,
        referenceDate: Date,
        timeZone: TimeZone,
        strict: Bool = false
    ) -> [ChatMessage] {
        let toolList = toolRegistry.modules.map { module in
            var lines = [
                "- name: \(module.definition.name)",
                "  domain: \(module.routingMetadata.domain)",
                "  purpose: \(module.definition.summary)",
            ]
            if let useWhen = module.definition.useWhen, useWhen.isEmpty == false {
                lines.append("  use_when: \(useWhen)")
            }
            if let avoidWhen = module.definition.avoidWhen, avoidWhen.isEmpty == false {
                lines.append("  avoid_when: \(avoidWhen)")
            }
            if module.definition.examples.isEmpty == false {
                lines.append("  examples: \(module.definition.examples.joined(separator: " | "))")
            }
            if let returns = module.definition.returns, returns.isEmpty == false {
                lines.append("  returns: \(returns)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")

        let transcript = messages.suffix(4).map { message in
            "\(message.role): \(message.content)"
        }.joined(separator: "\n")

        let referenceSummary = renderReferenceSummary(referenceDate: referenceDate, timeZone: timeZone)
        let lastToolSummary = renderLastToolSummary(
            lastToolCall: lastToolCall,
            toolRegistry: toolRegistry,
            referenceDate: referenceDate,
            timeZone: timeZone
        )
        let renderedSessionSummary = renderSessionSummary(sessionSummary)

        let system = """
        You are not the assistant. You are the router for apfelclaw.
        Your only job is to decide whether the next step should use exactly one tool or answer directly.
        \(referenceSummary)

        Choose use_tool when:
        - the user wants fresh personal data or current system data
        - the user is continuing a tool-backed request
        - the previous tool result does not explicitly cover the current request scope
        - an allowed tool can answer from local, personal, or time-sensitive data

        Choose answer_directly only when:
        - the user is greeting, chatting casually, or asking for stable general knowledge
        - the reply can be answered from stable assistant knowledge
        - the answer is already present in the conversation
        - no allowed tool is needed to answer reliably

        Small-model rule: greetings and pure chat can be answer_directly. Requests about the user's calendar, mail, files, or current Mac state should prefer use_tool.
        When in doubt between answer_directly and use_tool for local, personal, current, or changing data, prefer use_tool.
        Final-check rule: if the latest user message on its own clearly asks to read personal, local, or current data, choose use_tool even if earlier messages look conversational.

        Examples:
        - "Hello." -> {"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}
        - "How are you?" -> {"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}
        - "Please show me my calendar events for today." -> {"action":"use_tool","toolName":"list_calendar_events","reasonCode":"fresh_personal_data"}
        - "Add my weekly sync meeting for today at 14:00 to my calendar." -> {"action":"use_tool","toolName":"add_calendar_event","reasonCode":"fresh_personal_data"}
        - "Show me my recent emails." -> {"action":"use_tool","toolName":"list_recent_mail","reasonCode":"fresh_personal_data"}

        Return JSON only in this shape:
        {"action":"...","toolName":"... or null","reasonCode":"..."}

        Allowed action values: use_tool, answer_directly
        Allowed reasonCode values: fresh_personal_data, same_domain_follow_up, prior_result_insufficient, direct_answer_ok, other

        Valid examples:
        {"action":"use_tool","toolName":"list_calendar_events","reasonCode":"fresh_personal_data"}
        {"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}

        Rules:
        - toolName must be null when action is answer_directly.
        - toolName must exactly match one of the allowed tools when action is use_tool.
        - reasonCode must be direct_answer_ok or other when action is answer_directly.
        - reasonCode must not be direct_answer_ok when action is use_tool.
        - Requests to read the user's own mail, calendar, files, or current system state should use a tool when an allowed tool fits.
        - Requests to create or change the user's own calendar events should use a tool when an allowed tool fits.
        - This stage is classification only. Never emit function calls or tool_calls.
        - Never return markdown, code fences, or extra prose.

        \(strict ? "Previous output was invalid. Retry and return exactly one JSON object matching the schema." : "")

        Allowed tools:
        \(toolList)
        """

        let user = """
        Recent conversation:
        \(transcript)

        \(renderedSessionSummary)

        \(lastToolSummary)

        Latest user message:
        \(userInput)
        """

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }

    static func buildFollowUpVerificationMessages(
        messages: [(role: String, content: String)],
        userInput: String,
        sessionSummary: String?,
        lastToolCall: ToolCallRecord,
        toolRegistry: ToolRegistry,
        referenceDate: Date,
        timeZone: TimeZone,
        strict: Bool = false
    ) -> [ChatMessage] {
        let transcript = messages.suffix(4).map { message in
            "\(message.role): \(message.content)"
        }.joined(separator: "\n")
        let referenceSummary = renderReferenceSummary(referenceDate: referenceDate, timeZone: timeZone)
        let lastToolSummary = renderLastToolSummary(
            lastToolCall: lastToolCall,
            toolRegistry: toolRegistry,
            referenceDate: referenceDate,
            timeZone: timeZone
        )
        let renderedSessionSummary = renderSessionSummary(sessionSummary)

        let system = """
        You are checking whether the user's latest message continues the previous tool-backed request.
        You are not deciding arguments.
        \(referenceSummary)

        If the previous tool result covered only one scope and the user is asking for a different or fresh scope, reuse the same tool.

        Return JSON only in this shape:
        {"reuseLastTool":true,"reasonCode":"..."}

        Allowed reasonCode values: fresh_personal_data, same_domain_follow_up, prior_result_insufficient, direct_answer_ok, other

        Valid examples:
        {"reuseLastTool":true,"reasonCode":"same_domain_follow_up"}
        {"reuseLastTool":false,"reasonCode":"direct_answer_ok"}

        Rules:
        - reuseLastTool is true only when the latest user message is still in the same tool-backed domain and needs a fresh or changed scope.
        - reuseLastTool is false if the user switched domains or is asking a normal conversational question.
        - reasonCode must not be direct_answer_ok when reuseLastTool is true.
        - reasonCode must be direct_answer_ok or other when reuseLastTool is false.
        - This stage is classification only. Never emit function calls or tool_calls.
        - Never return markdown, code fences, or extra prose.

        \(strict ? "Previous output was invalid. Retry and return exactly one JSON object matching the schema." : "")
        """

        let user = """
        Recent conversation:
        \(transcript)

        \(renderedSessionSummary)

        \(lastToolSummary)

        Latest user message:
        \(userInput)
        """

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }

    private static func recoverToolFromFollowUpReuse(
        initialSelection: ToolIntentSelection?,
        messages: [(role: String, content: String)],
        userInput: String,
        sessionSummary: String?,
        lastToolCall: ToolCallRecord?,
        toolRegistry: ToolRegistry,
        modelClient: any ModelCompleting,
        referenceDate: Date,
        timeZone: TimeZone,
        debugLog: (@Sendable (String) -> Void)?
    ) async throws -> (RoutingDecision?, [RoutingDebugAttempt], RoutingSelectionStatus) {
        guard initialSelection?.action != .useTool,
              let lastToolCall,
              lastToolCall.approved,
              let lastModule = toolRegistry.module(named: lastToolCall.toolName),
              lastModule.routingMetadata.supportsFollowUpReuse
        else {
            return (nil, [], .exhausted)
        }

        let (verification, attempts, status) = try await requestFollowUpReuseSelection(
            messages: messages,
            userInput: userInput,
            sessionSummary: sessionSummary,
            lastToolCall: lastToolCall,
            toolRegistry: toolRegistry,
            modelClient: modelClient,
            referenceDate: referenceDate,
            timeZone: timeZone,
            debugLog: debugLog
        )
        guard let verification,
              verification.reuseLastTool
        else {
            return (nil, attempts, status)
        }

        return (
            RoutingDecision(
                action: .useTool,
                toolName: lastToolCall.toolName,
                reasonCode: verification.reasonCode
            ),
            attempts,
            status
        )
    }

    private static func parseSelection(from content: String) -> ToolIntentSelection? {
        guard let raw = decodeJSON(content, as: RawToolIntentSelection.self),
              let action = RoutingAction(rawValue: raw.action) else {
            return nil
        }

        let reasonCode: RoutingReasonCode
        switch action {
        case .answerDirectly:
            reasonCode = normalizeReasonCode(raw.reasonCode, fallback: .directAnswerOK)
        case .useTool:
            reasonCode = normalizeReasonCode(raw.reasonCode, fallback: .freshPersonalData, disallowDirectAnswer: true)
        case .clarify:
            return nil
        }

        return ToolIntentSelection(action: action, toolName: normalizeNullableString(raw.toolName), reasonCode: reasonCode)
    }

    private static func parseFollowUpReuse(from content: String) -> FollowUpReuseSelection? {
        guard let raw = decodeJSON(content, as: RawFollowUpReuseSelection.self) else {
            return nil
        }

        let fallback: RoutingReasonCode = raw.reuseLastTool ? .sameDomainFollowUp : .directAnswerOK
        let reasonCode = normalizeReasonCode(raw.reasonCode, fallback: fallback, disallowDirectAnswer: raw.reuseLastTool)
        return FollowUpReuseSelection(reuseLastTool: raw.reuseLastTool, reasonCode: reasonCode)
    }

    private static func requestClassifierSelection(
        messages: [(role: String, content: String)],
        userInput: String,
        sessionSummary: String?,
        lastToolCall: ToolCallRecord?,
        toolRegistry: ToolRegistry,
        modelClient: any ModelCompleting,
        referenceDate: Date,
        timeZone: TimeZone,
        debugLog: (@Sendable (String) -> Void)?
    ) async throws -> (ToolIntentSelection?, [RoutingDebugAttempt], RoutingSelectionStatus) {
        let attempts = [false, true]
        var debugAttempts: [RoutingDebugAttempt] = []
        for strict in attempts {
            let classifierMessages = buildClassifierMessages(
                messages: messages,
                userInput: userInput,
                sessionSummary: sessionSummary,
                lastToolCall: lastToolCall,
                toolRegistry: toolRegistry,
                referenceDate: referenceDate,
                timeZone: timeZone,
                strict: strict
            )
            let outcome: CompletionOutcome
            do {
                outcome = try await modelClient.complete(
                    messages: classifierMessages,
                    tools: [],
                    mode: .structuredText
                )
            } catch {
                debugAttempts.append(RoutingDebugAttempt(stage: "classifier", strict: strict, status: "model_error", output: sanitizeDebugText(error.localizedDescription)))
                debugLog?("[debug][intent_router][classifier] strict=\(strict) model_error=\(sanitizeDebugText(error.localizedDescription))")
                return (nil, debugAttempts, .modelError)
            }
            guard let text = outcome.text else {
                debugAttempts.append(RoutingDebugAttempt(stage: "classifier", strict: strict, status: "empty_response", output: nil))
                debugLog?("[debug][intent_router][classifier] strict=\(strict) empty_response=true")
                continue
            }
            guard let selection = parseSelection(from: text) else {
                debugAttempts.append(RoutingDebugAttempt(stage: "classifier", strict: strict, status: "invalid_json", output: sanitizeDebugText(text)))
                debugLog?("[debug][intent_router][classifier] strict=\(strict) invalid_json=\(sanitizeDebugText(text))")
                continue
            }
            if isValidSelection(selection, toolRegistry: toolRegistry) {
                debugAttempts.append(RoutingDebugAttempt(stage: "classifier", strict: strict, status: "accepted", output: sanitizeDebugText(text)))
                return (selection, debugAttempts, .accepted)
            }
            debugAttempts.append(RoutingDebugAttempt(stage: "classifier", strict: strict, status: "invalid_selection", output: sanitizeDebugText(text)))
            debugLog?("[debug][intent_router][classifier] strict=\(strict) invalid_selection=\(sanitizeDebugText(text))")
        }
        return (nil, debugAttempts, .exhausted)
    }

    private static func requestFollowUpReuseSelection(
        messages: [(role: String, content: String)],
        userInput: String,
        sessionSummary: String?,
        lastToolCall: ToolCallRecord,
        toolRegistry: ToolRegistry,
        modelClient: any ModelCompleting,
        referenceDate: Date,
        timeZone: TimeZone,
        debugLog: (@Sendable (String) -> Void)?
    ) async throws -> (FollowUpReuseSelection?, [RoutingDebugAttempt], RoutingSelectionStatus) {
        let attempts = [false, true]
        var debugAttempts: [RoutingDebugAttempt] = []
        for strict in attempts {
            let verificationMessages = buildFollowUpVerificationMessages(
                messages: messages,
                userInput: userInput,
                sessionSummary: sessionSummary,
                lastToolCall: lastToolCall,
                toolRegistry: toolRegistry,
                referenceDate: referenceDate,
                timeZone: timeZone,
                strict: strict
            )
            let outcome: CompletionOutcome
            do {
                outcome = try await modelClient.complete(
                    messages: verificationMessages,
                    tools: [],
                    mode: .structuredText
                )
            } catch {
                debugAttempts.append(RoutingDebugAttempt(stage: "follow_up", strict: strict, status: "model_error", output: sanitizeDebugText(error.localizedDescription)))
                debugLog?("[debug][intent_router][follow_up] strict=\(strict) model_error=\(sanitizeDebugText(error.localizedDescription))")
                return (nil, debugAttempts, .modelError)
            }
            guard let text = outcome.text else {
                debugAttempts.append(RoutingDebugAttempt(stage: "follow_up", strict: strict, status: "empty_response", output: nil))
                debugLog?("[debug][intent_router][follow_up] strict=\(strict) empty_response=true")
                continue
            }
            if let verification = parseFollowUpReuse(from: text),
               isValidFollowUpReuseSelection(verification) {
                debugAttempts.append(RoutingDebugAttempt(stage: "follow_up", strict: strict, status: "accepted", output: sanitizeDebugText(text)))
                return (verification, debugAttempts, .accepted)
            }
            let issue = parseFollowUpReuse(from: text) == nil ? "invalid_json" : "invalid_selection"
            debugAttempts.append(RoutingDebugAttempt(stage: "follow_up", strict: strict, status: issue, output: sanitizeDebugText(text)))
            debugLog?("[debug][intent_router][follow_up] strict=\(strict) \(issue)=\(sanitizeDebugText(text))")
        }
        return (nil, debugAttempts, .exhausted)
    }

    private static func renderDebugTrace(_ attempts: [RoutingDebugAttempt]) -> String? {
        guard attempts.isEmpty == false,
              let data = try? JSONEncoder().encode(RoutingDebugTracePayload(attempts: attempts)),
              let rendered = String(data: data, encoding: .utf8) else {
            return nil
        }
        return rendered
    }

    private static func sanitizeDebugText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func isValidSelection(_ selection: ToolIntentSelection, toolRegistry: ToolRegistry) -> Bool {
        switch selection.action {
        case .answerDirectly:
            guard selection.toolName == nil else {
                return false
            }
            return selection.reasonCode == .directAnswerOK || selection.reasonCode == .other
        case .useTool:
            guard let toolName = selection.toolName,
                  toolRegistry.module(named: toolName) != nil else {
                return false
            }
            return selection.reasonCode != .directAnswerOK
        case .clarify:
            return false
        }
    }

    private static func isValidFollowUpReuseSelection(_ selection: FollowUpReuseSelection) -> Bool {
        if selection.reuseLastTool {
            return selection.reasonCode != .directAnswerOK
        }
        return selection.reasonCode == .directAnswerOK || selection.reasonCode == .other
    }

    private static func decodeJSON<T: Decodable>(_ content: String, as type: T.Type) -> T? {
        let candidates = [content, stripCodeFence(from: content)].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let decoder = JSONDecoder()
        for candidate in candidates where candidate.isEmpty == false {
            if let data = candidate.data(using: .utf8),
               let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }

        return nil
    }

    private static func normalizeNullableString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        if value == "null" {
            return nil
        }
        return value
    }

    private static func normalizeReasonCode(
        _ rawValue: String,
        fallback: RoutingReasonCode,
        disallowDirectAnswer: Bool = false
    ) -> RoutingReasonCode {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = RoutingReasonCode(rawValue: trimmed), !(disallowDirectAnswer && exact == .directAnswerOK) {
            return exact
        }

        let options = trimmed
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for option in options {
            guard let normalized = RoutingReasonCode(rawValue: option) else {
                continue
            }
            if disallowDirectAnswer && normalized == .directAnswerOK {
                continue
            }
            return normalized
        }

        return fallback
    }

    private static func stripCodeFence(from content: String) -> String? {
        guard content.hasPrefix("```"), content.hasSuffix("```") else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        guard lines.count >= 3 else {
            return nil
        }

        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func renderSessionSummary(_ sessionSummary: String?) -> String {
        guard let sessionSummary = sessionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              sessionSummary.isEmpty == false else {
            return "Session summary: none."
        }
        return "Session summary:\n\(sessionSummary)"
    }

    private static func renderReferenceSummary(referenceDate: Date, timeZone: TimeZone) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone

        let absoluteFormatter = DateFormatter()
        absoluteFormatter.locale = Locale(identifier: "en_US_POSIX")
        absoluteFormatter.timeZone = timeZone
        absoluteFormatter.dateStyle = .long
        absoluteFormatter.timeStyle = .none

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate

        return """
        Reference time: \(isoFormatter.string(from: referenceDate)).
        User timezone: \(timeZone.identifier).
        "Today" means \(absoluteFormatter.string(from: referenceDate)).
        "Tomorrow" means \(absoluteFormatter.string(from: tomorrow)).
        """
    }

    private static func renderLastToolSummary(
        lastToolCall: ToolCallRecord?,
        toolRegistry: ToolRegistry,
        referenceDate: Date,
        timeZone: TimeZone
    ) -> String {
        guard let lastToolCall, lastToolCall.approved else {
            return "Last successful tool call: none."
        }

        guard let module = toolRegistry.module(named: lastToolCall.toolName) else {
            return "Last successful tool call: \(lastToolCall.toolName)."
        }

        var lines: [String] = [
            "Last successful tool call:",
            "- toolName: \(lastToolCall.toolName)",
            "- domain: \(module.routingMetadata.domain)",
            "- createdAt: \(lastToolCall.createdAt)",
        ]

        if let snapshot = summarizePayload(
            for: lastToolCall,
            module: module,
            referenceDate: referenceDate,
            timeZone: timeZone
        ) {
            lines.append("- scopeSummary: \(snapshot.scopeSummary)")
            if let scope = snapshot.machineReadableScope {
                lines.append("- machineReadableScope: \(renderJSONValue(scope))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func summarizePayload(
        for toolCall: ToolCallRecord,
        module: any ToolModule,
        referenceDate: Date,
        timeZone: TimeZone
    ) -> ToolResultSnapshot? {
        guard let data = toolCall.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(LoggedToolPayload.self, from: data)
        else {
            return nil
        }

        return module.summarizeLastResult(
            payload.result,
            context: ToolPresentationContext(referenceDate: referenceDate, timeZone: timeZone)
        )
    }

    private static func renderJSONValue(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let rendered = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return rendered
    }
}
