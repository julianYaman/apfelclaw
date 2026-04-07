import Foundation

public enum CommandSource: Sendable, Equatable {
    case telegram
}

public struct CommandHandlingResult: Sendable {
    public let handled: Bool
    public let responseText: String?
    public let sessionID: Int64?

    public init(handled: Bool, responseText: String? = nil, sessionID: Int64? = nil) {
        self.handled = handled
        self.responseText = responseText
        self.sessionID = sessionID
    }
}

public actor CommandService {
    private let configService: ConfigService
    private let conversationService: ConversationService

    public init(configService: ConfigService, conversationService: ConversationService) {
        self.configService = configService
        self.conversationService = conversationService
    }

    public func handleIfNeeded(
        content: String,
        sessionID: Int64,
        source: CommandSource
    ) async throws -> CommandHandlingResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return CommandHandlingResult(handled: false)
        }

        if trimmed == "/help" || trimmed == "/start" {
            return CommandHandlingResult(handled: true, responseText: helpText(for: source), sessionID: sessionID)
        }

        if trimmed == "/version" {
            return CommandHandlingResult(
                handled: true,
                responseText: "Apfelclaw server version: \(AppVersion.serverHeaderValue)",
                sessionID: sessionID
            )
        }

        if trimmed == "/config" {
            let config = await configService.current()
            return CommandHandlingResult(
                handled: true,
                responseText: formatConfigSummary(config),
                sessionID: sessionID
            )
        }

        if let parsedUpdate = parseConfigSetCommand(trimmed) {
            let update = try parsedUpdate.get()
            let updated = try await configService.update(update)
            return CommandHandlingResult(
                handled: true,
                responseText: "Updated config.\n\(formatConfigSummary(updated))",
                sessionID: sessionID
            )
        }

        if trimmed == "/new" {
            let session = try conversationService.createSession(title: source == .telegram ? "Telegram Session" : nil)
            return CommandHandlingResult(
                handled: true,
                responseText: "Started a new session (#\(session.id)).",
                sessionID: session.id
            )
        }

        if trimmed.hasPrefix("/remotecontrol") {
            return CommandHandlingResult(
                handled: true,
                responseText: "This command is only available in the local TUI.",
                sessionID: sessionID
            )
        }

        return CommandHandlingResult(
            handled: true,
            responseText: "Unknown command. Use /help.",
            sessionID: sessionID
        )
    }

    private func parseConfigSetCommand(_ content: String) -> Result<EditableAppConfigUpdate, AppError>? {
        let pattern = #"^/config\s+set\s+(assistantName|userName|approvalMode|debug)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range), match.numberOfRanges == 3,
              let fieldRange = Range(match.range(at: 1), in: content),
              let valueRange = Range(match.range(at: 2), in: content)
        else {
            return nil
        }

        let field = String(content[fieldRange])
        let value = String(content[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case "assistantName":
            return .success(EditableAppConfigUpdate(assistantName: value))
        case "userName":
            return .success(EditableAppConfigUpdate(userName: value))
        case "approvalMode":
            return .success(EditableAppConfigUpdate(approvalMode: value))
        case "debug":
            guard value == "true" || value == "false" else {
                return .failure(AppError.message("debug must be either true or false."))
            }
            return .success(EditableAppConfigUpdate(debug: value == "true"))
        default:
            return nil
        }
    }

    private func formatConfigSummary(_ config: EditableAppConfig) -> String {
        [
            "assistantName: \(config.assistantName)",
            "userName: \(config.userName)",
            "approvalMode: \(config.approvalMode)",
            "debug: \(config.debug)",
        ].joined(separator: "\n")
    }

    private func helpText(for source: CommandSource) -> String {
        var lines = [
            "Slash commands:",
            "/new starts a fresh session.",
            "/help shows this message.",
            "/version shows the server version.",
            "/config shows config.",
            "/config set assistantName <value>",
            "/config set userName <value>",
            "/config set approvalMode <always|ask-once-per-tool-per-session|trusted-readonly>",
            "/config set debug <true|false>",
        ]
        if source == .telegram {
            lines.append("/remotecontrol is only available in the local TUI.")
        }
        return lines.joined(separator: "\n")
    }
}
