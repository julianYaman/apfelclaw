import Foundation

public enum RoutingAction: String, Codable, Sendable {
    case useTool = "use_tool"
    case answerDirectly = "answer_directly"
    case clarify = "clarify"
}

public struct RoutingDecision: Sendable {
    public let action: RoutingAction
    public let toolName: String?
    public let debugTrace: String?

    public init(action: RoutingAction, toolName: String?, debugTrace: String? = nil) {
        self.action = action
        self.toolName = toolName
        self.debugTrace = debugTrace
    }
}

private struct ToolIntentSelection: Equatable {
    let toolName: String?
}

private struct RawToolIntentSelection: Decodable {
    let toolName: String?

    enum CodingKeys: String, CodingKey {
        case toolName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.toolName) else {
            throw DecodingError.keyNotFound(
                CodingKeys.toolName,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "toolName is required")
            )
        }
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    }
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
        let (selection, debugAttempts) = try await requestClassifierSelection(
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
        let debugTrace = renderDebugTrace(debugAttempts)

        if let toolName = selection?.toolName {
            return RoutingDecision(action: .useTool, toolName: toolName, debugTrace: debugTrace)
        }

        if selection != nil {
            return RoutingDecision(action: .answerDirectly, toolName: nil, debugTrace: debugTrace)
        }

        return RoutingDecision(action: .clarify, toolName: nil, debugTrace: debugTrace)
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
        let allowedToolNames = toolRegistry.modules.map(\.definition.name)
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
        let allowedNames = allowedToolNames.joined(separator: ", ")

        let system = """
        You are not the assistant. You are the router for apfelclaw.
        Your only job is to choose exactly one allowed tool name, or null.
        \(referenceSummary)

        Return JSON only in this shape:
        {"toolName":"<one allowed tool name or null>"}

        Choose a tool when:
        - the user wants fresh personal, local, or current data
        - the user wants to create or change local personal data such as a calendar event
        - the user is continuing a previous lookup with a new or changed scope
        - an allowed tool can answer from local, personal, or time-sensitive data

        Choose null only when:
        - the user is greeting, chatting casually, or asking for stable general knowledge
        - the answer is already present in the conversation
        - no allowed tool is needed

        When in doubt for local, personal, current, or changing data, choose a tool.
        If the latest user message on its own clearly asks to read or change personal, local, or current data, choose that tool even if earlier messages look conversational.
        If the last tool allows follow-up reuse and the user asks for a changed or fresh scope of that same lookup, choose that same tool again.
        Do not reuse a tool whose follow-up reuse is not allowed unless the user is clearly asking for that same action again.

        Examples:
        - "Hello." -> {"toolName":null}
        - "How are you?" -> {"toolName":null}
        - "Please show me my calendar events for today." -> {"toolName":"list_calendar_events"}
        - "Add my weekly sync meeting for today at 14:00 to my calendar." -> {"toolName":"add_calendar_event"}
        - "Show me my recent emails." -> {"toolName":"list_recent_mail"}
        - Previous calendar lookup covered today, user says "And for tomorrow?" -> {"toolName":"list_calendar_events"}
        - Previous mail lookup, user says "show me more" -> {"toolName":"list_recent_mail"}

        Rules:
        - toolName must be null or exactly one of: \(allowedNames)
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

    private static func parseSelection(from content: String) -> ToolIntentSelection? {
        guard let raw = decodeJSON(content, as: RawToolIntentSelection.self) else {
            return nil
        }
        return ToolIntentSelection(toolName: normalizeNullableString(raw.toolName))
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
    ) async throws -> (ToolIntentSelection?, [RoutingDebugAttempt]) {
        let attempts = [false, true]
        var debugAttempts: [RoutingDebugAttempt] = []
        let schema = classifierOutputSchema(allowedToolNames: toolRegistry.modules.map(\.definition.name))
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
                    mode: .structuredText,
                    responseSchema: schema
                )
            } catch {
                debugAttempts.append(RoutingDebugAttempt(stage: "classifier", strict: strict, status: "model_error", output: sanitizeDebugText(error.localizedDescription)))
                debugLog?("[debug][intent_router][classifier] strict=\(strict) model_error=\(sanitizeDebugText(error.localizedDescription))")
                return (nil, debugAttempts)
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
                return (selection, debugAttempts)
            }
            debugAttempts.append(RoutingDebugAttempt(stage: "classifier", strict: strict, status: "invalid_selection", output: sanitizeDebugText(text)))
            debugLog?("[debug][intent_router][classifier] strict=\(strict) invalid_selection=\(sanitizeDebugText(text))")
        }
        return (nil, debugAttempts)
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
        guard let toolName = selection.toolName else {
            return true
        }
        return toolRegistry.module(named: toolName) != nil
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
            "- followUpReuse: \(module.routingMetadata.supportsFollowUpReuse ? "yes" : "no")",
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

    static func classifierOutputSchema(allowedToolNames: [String]) -> StructuredOutputSchema {
        let toolNameSchema: JSONValue
        if allowedToolNames.isEmpty {
            toolNameSchema = .object(["type": .string("null")])
        } else {
            toolNameSchema = .object([
                "anyOf": .array([
                    stringEnum(allowedToolNames),
                    .object(["type": .string("null")]),
                ]),
            ])
        }

        return StructuredOutputSchema(
            name: "intent_classifier",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "toolName": toolNameSchema,
                ]),
                "required": .array([
                    .string("toolName"),
                ]),
            ])
        )
    }

    private static func stringEnum(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }
}
