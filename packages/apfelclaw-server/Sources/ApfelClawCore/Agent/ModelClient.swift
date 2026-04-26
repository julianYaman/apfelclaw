import Foundation

public enum CompletionMode: Sendable {
    case structuredText
    case userFacingText
    case toolAware
}

public protocol ModelCompleting: Sendable {
    func complete(messages: [ChatMessage], tools: [ToolDefinition], mode: CompletionMode) async throws -> CompletionOutcome
}

public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String?
    public let name: String?
    public let toolCallID: String?
    public let toolCalls: [ChatToolCall]?

    public init(
        role: String,
        content: String?,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [ChatToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

public struct ChatToolCall: Codable, Sendable {
    public struct FunctionCall: Codable, Sendable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public let id: String
    public let type: String
    public let function: FunctionCall

    public init(id: String, type: String, function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct CompletionOutcome: Sendable {
    public let text: String?
    public let toolCall: ToolCall?
}

public final class ModelClient: ModelCompleting, Sendable {
    private let baseURL = URL(string: "http://127.0.0.1:11434/v1/chat/completions")!

    public init() {}

    public func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        mode: CompletionMode = .toolAware
    ) async throws -> CompletionOutcome {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ChatCompletionRequest(
            model: "apple-foundationmodel",
            messages: messages,
            temperature: 0.2,
            maxTokens: 500,
            tools: tools.isEmpty ? nil : tools.map(ChatCompletionRequest.Tool.init)
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.message("apfel returned a non-HTTP response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw AppError.message("apfel request failed (\(http.statusCode)): \(body)")
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = completion.choices.first else {
            throw AppError.message("apfel returned no choices.")
        }

        let content = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .structuredText:
            if let content, content.isEmpty == false {
                return CompletionOutcome(text: content, toolCall: nil)
            }
            if let toolCalls = choice.message.toolCalls,
               let serializedToolCalls = Self.serializeToolCalls(toolCalls) {
                return CompletionOutcome(text: serializedToolCalls, toolCall: nil)
            }
        case .userFacingText:
            if let content, content.isEmpty == false {
                return CompletionOutcome(text: content, toolCall: nil)
            }
            if choice.message.toolCalls?.isEmpty == false {
                throw AppError.message("apfel returned tool calls when plain text was expected.")
            }
        case .toolAware:
            if let toolCall = choice.message.toolCalls?.first {
                return CompletionOutcome(text: nil, toolCall: Self.normalizeToolCall(toolCall))
            }
            if let content, content.isEmpty == false {
                if let toolCall = Self.extractToolCall(from: content) {
                    return CompletionOutcome(text: nil, toolCall: toolCall)
                }
                return CompletionOutcome(text: content, toolCall: nil)
            }
        }

        throw AppError.message("apfel returned an empty response.")
    }

    static func normalizeToolCall(_ toolCall: ChatToolCall) -> ToolCall {
        if SafeCommandRegistry.commands.contains(where: { $0.name == toolCall.function.name }) {
            return ToolCall(
                id: toolCall.id,
                name: "run_safe_command",
                argumentsJSON: normalizedSafeCommandArguments(command: toolCall.function.name)
            )
        }

        return ToolCall(
            id: toolCall.id,
            name: toolCall.function.name,
            argumentsJSON: toolCall.function.arguments
        )
    }

    static func extractToolCall(from content: String) -> ToolCall? {
        let stripped = stripCodeFence(from: content)
        let strippedObject = stripped.flatMap { extractJSONObject(from: $0) }
        let candidates = [content, stripped, extractJSONObject(from: content), strippedObject].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let decoder = JSONDecoder()
        for candidate in candidates where candidate.isEmpty == false {
            if let data = candidate.data(using: .utf8),
               let payload = try? decoder.decode(FallbackToolCallPayload.self, from: data),
               let first = payload.toolCalls.first {
                return normalizeToolCall(first)
            }

            if let data = candidate.data(using: .utf8),
               let payload = try? decoder.decode(LooseFallbackToolCallPayload.self, from: data),
               let first = payload.toolCalls.first {
                return normalizeLooseToolCall(first)
            }
        }

        return nil
    }

    private static func serializeToolCalls(_ toolCalls: [ChatToolCall]) -> String? {
        guard let data = try? JSONEncoder().encode(FallbackToolCallPayload(toolCalls: toolCalls)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func stripCodeFence(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else {
            return nil
        }

        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func extractJSONObject(from content: String) -> String? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}") else {
            return nil
        }

        return String(content[start ... end])
    }

    private static func normalizedSafeCommandArguments(command: String) -> String {
        #"{"command":"\#(command)","arguments":[]}"#
    }

    private static func normalizeLooseToolCall(_ toolCall: LooseChatToolCall) -> ToolCall? {
        let name = toolCall.function.name

        if SafeCommandRegistry.commands.contains(where: { $0.name == name }) {
            return ToolCall(
                id: toolCall.id,
                name: "run_safe_command",
                argumentsJSON: normalizedSafeCommandArguments(command: name)
            )
        }

        guard let argumentsJSON = toolCall.function.arguments.renderedJSONString else {
            return nil
        }

        return ToolCall(
            id: toolCall.id,
            name: name,
            argumentsJSON: argumentsJSON
        )
    }
}

private struct ChatCompletionRequest: Codable {
    struct Tool: Codable {
        struct Function: Codable {
            let name: String
            let description: String
            let parameters: JSONValue
        }

        let type: String
        let function: Function

        init(definition: ToolDefinition) {
            self.type = "function"
            self.function = Function(
                name: definition.name,
                description: definition.description,
                parameters: definition.parameters
            )
        }
    }

    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int
    let tools: [Tool]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case tools
    }
}

private struct ChatCompletionResponse: Codable {
    struct Choice: Codable {
        struct ResponseMessage: Codable {
            let role: String
            let content: String?
            let toolCalls: [ChatToolCall]?

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case toolCalls = "tool_calls"
            }
        }

        let message: ResponseMessage
    }

    let choices: [Choice]
}

private struct FallbackToolCallPayload: Codable {
    let toolCalls: [ChatToolCall]

    enum CodingKeys: String, CodingKey {
        case toolCalls = "tool_calls"
    }
}

private struct LooseFallbackToolCallPayload: Codable {
    let toolCalls: [LooseChatToolCall]

    enum CodingKeys: String, CodingKey {
        case toolCalls = "tool_calls"
    }
}

private struct LooseChatToolCall: Codable {
    struct FunctionCall: Codable {
        let name: String
        let arguments: FlexibleToolArguments
    }

    let id: String
    let type: String
    let function: FunctionCall
}

private enum FlexibleToolArguments: Codable {
    case string(String)
    case json(JSONValue)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        let json = try container.decode(JSONValue.self)
        self = .json(json)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .json(value):
            try container.encode(value)
        }
    }

    var renderedJSONString: String? {
        switch self {
        case let .string(value):
            return value
        case let .json(value):
            guard let data = try? JSONEncoder().encode(value) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }
}
