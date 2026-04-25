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
    private let apfelUpdateService: ApfelUpdateService?
    private let apfelMaintenanceService: ApfelMaintenanceService?

    public init(
        configService: ConfigService,
        conversationService: ConversationService,
        apfelUpdateService: ApfelUpdateService? = nil,
        apfelMaintenanceService: ApfelMaintenanceService? = nil
    ) {
        self.configService = configService
        self.conversationService = conversationService
        self.apfelUpdateService = apfelUpdateService
        self.apfelMaintenanceService = apfelMaintenanceService
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
                responseText: await versionText(),
                sessionID: sessionID
            )
        }

        if let apfelCommand = parseApfelCommand(trimmed) {
            return try await handleApfelCommand(apfelCommand, sessionID: sessionID)
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
            "/version shows the server and apfel version.",
            "/apfel status shows update and maintenance status.",
            "/apfel restart asks for restart confirmation.",
            "/apfel restart confirm restarts apfel when supported.",
            "/apfel upgrade asks for upgrade confirmation.",
            "/apfel upgrade confirm upgrades Homebrew apfel and restarts it when supported.",
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

    private func versionText() async -> String {
        var lines = ["Apfelclaw server version: \(AppVersion.serverHeaderValue)"]

        guard let apfelUpdateService, let apfelMaintenanceService else {
            return lines.joined(separator: "\n")
        }

        _ = await apfelUpdateService.refreshNow()
        let maintenance = await apfelMaintenanceService.currentState()
        let status = await apfelUpdateService.currentResponse(maintenance: maintenance)
        lines.append("")
        lines.append(contentsOf: formatApfelStatus(status))
        return lines.joined(separator: "\n")
    }

    private func handleApfelCommand(_ command: ApfelCommand, sessionID: Int64) async throws -> CommandHandlingResult {
        guard let apfelUpdateService, let apfelMaintenanceService else {
            return CommandHandlingResult(
                handled: true,
                responseText: "apfel update commands are unavailable in this server build.",
                sessionID: sessionID
            )
        }

        switch command {
        case .status:
            _ = await apfelUpdateService.refreshNow()
            let maintenance = await apfelMaintenanceService.currentState()
            let status = await apfelUpdateService.currentResponse(maintenance: maintenance)
            return CommandHandlingResult(
                handled: true,
                responseText: formatApfelStatus(status).joined(separator: "\n"),
                sessionID: sessionID
            )
        case .restart(confirm: false):
            return CommandHandlingResult(
                handled: true,
                responseText: "Restarting apfel interrupts model requests for a short time. Run /apfel restart confirm to continue.",
                sessionID: sessionID
            )
        case .upgrade(confirm: false):
            return CommandHandlingResult(
                handled: true,
                responseText: "Upgrading apfel may briefly interrupt model requests. Run /apfel upgrade confirm to continue.",
                sessionID: sessionID
            )
        case .restart(confirm: true):
            let result = try await apfelMaintenanceService.restart()
            return CommandHandlingResult(handled: true, responseText: renderApfelActionResult(result), sessionID: sessionID)
        case .upgrade(confirm: true):
            let result = try await apfelMaintenanceService.upgrade()
            return CommandHandlingResult(handled: true, responseText: renderApfelActionResult(result), sessionID: sessionID)
        }
    }

    private func renderApfelActionResult(_ result: ApfelActionResponse) -> String {
        ([result.message, ""] + formatApfelStatus(result.status)).joined(separator: "\n")
    }

    private func formatApfelStatus(_ status: ApfelStatusResponse) -> [String] {
        var lines = [
            "apfel installedVersion: \(status.installedVersion ?? "unknown")",
            "apfel latestVersion: \(status.latestVersion ?? "unknown")",
            "apfel installSource: \(status.installSource)",
            "apfel updateAvailable: \(status.updateAvailable)",
            "apfel canUpgrade: \(status.canUpgrade)",
            "apfel canRestart: \(status.canRestart) [\(status.restartMode)]",
        ]

        if let executablePath = status.executablePath {
            lines.append("apfel executablePath: \(executablePath)")
        }
        if let upgradeCommand = status.upgradeCommand {
            lines.append("apfel upgradeCommand: \(upgradeCommand)")
        }
        if let releaseURL = status.releaseURL {
            lines.append("apfel releaseURL: \(releaseURL)")
        }
        if let lastCheckedAt = status.lastCheckedAt {
            lines.append("apfel lastCheckedAt: \(lastCheckedAt)")
        }
        if let lastError = status.lastError {
            lines.append("apfel lastError: \(lastError)")
        }
        if status.maintenance.inProgress {
            lines.append("apfel maintenance: \(status.maintenance.operation ?? "unknown")")
            if let message = status.maintenance.message {
                lines.append("apfel maintenanceMessage: \(message)")
            }
        }
        return lines
    }

    private func parseApfelCommand(_ content: String) -> ApfelCommand? {
        switch content {
        case "/apfel status":
            return .status
        case "/apfel restart":
            return .restart(confirm: false)
        case "/apfel restart confirm":
            return .restart(confirm: true)
        case "/apfel upgrade":
            return .upgrade(confirm: false)
        case "/apfel upgrade confirm":
            return .upgrade(confirm: true)
        default:
            return nil
        }
    }
}

private enum ApfelCommand {
    case status
    case restart(confirm: Bool)
    case upgrade(confirm: Bool)
}
