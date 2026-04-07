import Foundation

public struct ToolDefinition: Sendable {
    public let name: String
    public let summary: String
    public let description: String
    public let readonly: Bool
    public let requiresConfirmation: Bool
    public let resultFormat: String
    public let useWhen: String?
    public let avoidWhen: String?
    public let examples: [String]
    public let returns: String?
    public let parameters: JSONValue

    init(entry: ToolManifestEntry) {
        self.name = entry.name
        self.summary = entry.description
        self.useWhen = entry.useWhen
        self.avoidWhen = entry.avoidWhen
        self.examples = entry.examples ?? []
        self.returns = entry.returns
        self.description = ToolDefinition.composeDescription(from: entry)
        self.readonly = entry.readonly
        self.requiresConfirmation = entry.requiresConfirmation
        self.resultFormat = entry.resultFormat
        self.parameters = entry.parameters
    }

    private static func composeDescription(from entry: ToolManifestEntry) -> String {
        var parts: [String] = [entry.description]

        if let useWhen = entry.useWhen, useWhen.isEmpty == false {
            parts.append("Use when: \(useWhen)")
        }

        if let avoidWhen = entry.avoidWhen, avoidWhen.isEmpty == false {
            parts.append("Avoid when: \(avoidWhen)")
        }

        if let returns = entry.returns, returns.isEmpty == false {
            parts.append("Returns: \(returns)")
        }

        if let examples = entry.examples, examples.isEmpty == false {
            let renderedExamples = examples.map { "\"\($0)\"" }.joined(separator: "; ")
            parts.append("Examples: \(renderedExamples)")
        }

        return parts.joined(separator: " ")
    }
}

public struct ToolCall: Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public final class ToolRegistry: @unchecked Sendable {
    public let modules: [any ToolModule]
    private let modulesByName: [String: any ToolModule]

    public init() throws {
        let manifest = try ToolCatalogLoader.loadManifest()
        self.modules = try manifest.tools.map(Self.makeModule)
        self.modulesByName = Dictionary(uniqueKeysWithValues: modules.map { ($0.definition.name, $0) })
        try validate()
    }

    public func module(named name: String) -> (any ToolModule)? {
        modulesByName[name]
    }

    public var definitions: [ToolDefinition] {
        modules.map(\.definition)
    }

    private func validate() throws {
        guard Set(modules.map(\.definition.name)).count == modules.count else {
            throw AppError.message("tools.json contains duplicate tool names.")
        }
    }

    private static func makeModule(entry: ToolManifestEntry) throws -> any ToolModule {
        let definition = ToolDefinition(entry: entry)
        switch entry.name {
        case "find_files":
            return FindFilesToolModule(definition: definition)
        case "get_file_info":
            return GetFileInfoToolModule(definition: definition)
        case "list_calendar_events":
            return CalendarEventsToolModule(definition: definition)
        case "run_safe_command":
            return SafeCommandToolModule(definition: definition)
        case "list_recent_mail":
            return RecentMailToolModule(definition: definition)
        default:
            throw AppError.message("tools.json defines unsupported tool '\(entry.name)'.")
        }
    }
}

public final class ToolRuntime: @unchecked Sendable {
    public let registry: ToolRegistry

    public init() throws {
        self.registry = try ToolRegistry()
    }

    public var availableTools: [ToolDefinition] {
        registry.definitions
    }

    public func execute(toolCall: ToolCall, userInput: String, context: ToolExecutionContext) async throws -> String {
        guard let module = registry.module(named: toolCall.name) else {
            throw AppError.message("Unsupported tool requested: \(toolCall.name)")
        }
        let arguments = parseArguments(module.normalizeArguments(toolCall.argumentsJSON, userInput: userInput, context: context))
        return try await module.execute(arguments: arguments, userInput: userInput, context: context)
    }

    public func definition(named name: String) -> ToolDefinition? {
        registry.module(named: name)?.definition
    }

    public func module(named name: String) -> (any ToolModule)? {
        registry.module(named: name)
    }

    public func deterministicFallbackToolCall(named name: String) -> ToolCall? {
        guard let module = registry.module(named: name), module.supportsDeterministicFallbackInvocation else {
            return nil
        }

        return ToolCall(
            id: "fallback_\(UUID().uuidString)",
            name: name,
            argumentsJSON: "{}"
        )
    }

    private func parseArguments(_ json: String) -> [String: JSONValue] {
        let data = Data(json.utf8)
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }
}

private enum ToolModuleSupport {
    static func decodeObject(_ result: String) -> [String: JSONValue]? {
        let data = Data(result.utf8)
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    static func encode(_ object: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(object)
        return String(decoding: data, as: UTF8.self)
    }

    static func requireString(_ value: JSONValue?, key: String) throws -> String {
        guard let string = value?.stringValue, string.isEmpty == false else {
            throw AppError.message("Tool argument '\(key)' is required.")
        }
        return string
    }

    static func clampLimit(_ value: Int?, fallback: Int, upperBound: Int) -> Int {
        guard let value else {
            return fallback
        }
        return min(Swift.max(1, value), upperBound)
    }

    static func inferCount(from userInput: String) -> Int? {
        let input = userInput.lowercased()

        if let range = input.range(of: #"\b([0-9]{1,2})\b"#, options: .regularExpression),
           let value = Int(input[range]) {
            return value
        }

        let wordMap: [String: Int] = [
            "one": 1,
            "two": 2,
            "three": 3,
            "four": 4,
            "five": 5,
            "six": 6,
            "seven": 7,
            "eight": 8,
            "nine": 9,
            "ten": 10,
        ]

        for (word, value) in wordMap where input.contains(word) {
            return value
        }

        return nil
    }

    static func resolveLimit(arguments: [String: JSONValue], userInput: String, fallback: Int, upperBound: Int) -> Int {
        if let explicit = arguments["limit"]?.intValue {
            return clampLimit(explicit, fallback: fallback, upperBound: upperBound)
        }
        if let inferred = inferCount(from: userInput) {
            return clampLimit(inferred, fallback: fallback, upperBound: upperBound)
        }
        return fallback
    }
}

private struct FindFilesToolModule: ToolModule {
    let definition: ToolDefinition
    let routingMetadata = ToolRoutingMetadata(domain: "files", supportsFollowUpReuse: false, followUpSummaryStyle: .generic)
    private let fileTools = FileTools()

    func execute(arguments: [String: JSONValue], userInput: String, context: ToolExecutionContext) async throws -> String {
        let query = try resolveQuery(arguments: arguments, userInput: userInput)
        let limit = ToolModuleSupport.resolveLimit(arguments: arguments, userInput: userInput, fallback: 5, upperBound: 10)
        return try fileTools.findFiles(query: query, limit: limit)
    }

    func summarizeResult(_ result: String, context: ToolPresentationContext) -> String? {
        guard
            let object = ToolModuleSupport.decodeObject(result),
            let results = object["results"]?.arrayValue
        else {
            return nil
        }

        if results.isEmpty {
            let query = object["query"]?.stringValue ?? "that query"
            return "I could not find any files for \(query)."
        }

        let lines = results.prefix(5).compactMap { item -> String? in
            item.objectValue?["path"]?.stringValue
        }

        guard lines.isEmpty == false else {
            return nil
        }

        if lines.count == 1 {
            return "I found one matching file: \(lines[0])."
        }

        return "I found these matching files:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    func summarizeLastResult(_ result: String, context: ToolPresentationContext) -> ToolResultSnapshot? {
        guard let object = ToolModuleSupport.decodeObject(result) else {
            return nil
        }
        let query = object["query"]?.stringValue ?? "previous file search"
        return ToolResultSnapshot(
            toolName: definition.name,
            domain: routingMetadata.domain,
            scopeSummary: "Previous file search query: \(query).",
            machineReadableScope: .object(["query": object["query"] ?? .null])
        )
    }

    func normalizeArguments(_ rawArgumentsJSON: String, userInput: String, context: ToolExecutionContext) -> String {
        guard let decoded = ToolModuleSupport.decodeObject(rawArgumentsJSON) else {
            return rawArgumentsJSON
        }

        var normalized: [String: JSONValue] = [:]
        if let query = decoded["query"]?.stringValue, query.isEmpty == false {
            normalized["query"] = .string(query)
        }
        if let limit = decoded["limit"]?.intValue {
            normalized["limit"] = .number(Double(limit))
        }
        return (try? ToolModuleSupport.encode(normalized)) ?? rawArgumentsJSON
    }

    private func resolveQuery(arguments: [String: JSONValue], userInput: String) throws -> String {
        if let query = arguments["query"]?.stringValue, query.isEmpty == false {
            return query
        }

        let cleaned = userInput
            .replacingOccurrences(of: #"(?i)\b(where is|find|locate|search for|show me|the|file|path|project|in this project)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\?\.\"]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.isEmpty == false else {
            throw AppError.message("Tool argument 'query' is required.")
        }
        return cleaned
    }
}

private struct GetFileInfoToolModule: ToolModule {
    let definition: ToolDefinition
    let routingMetadata = ToolRoutingMetadata(domain: "files", supportsFollowUpReuse: false, followUpSummaryStyle: .generic)
    private let fileTools = FileTools()

    func execute(arguments: [String: JSONValue], userInput: String, context: ToolExecutionContext) async throws -> String {
        let path = try resolvePath(arguments: arguments, userInput: userInput)
        return try fileTools.getFileInfo(path: path)
    }

    func summarizeResult(_ result: String, context: ToolPresentationContext) -> String? {
        guard let object = ToolModuleSupport.decodeObject(result) else {
            return nil
        }

        let path = object["path"]?.stringValue ?? "Unknown path"
        let type = object["type_description"]?.stringValue ?? ((object["is_directory"]?.boolValue == true) ? "folder" : "file")
        let size = object["file_size_bytes"]?.intValue.map { "\($0) bytes" }
        let modified = object["modified_at"]?.stringValue

        var parts = ["\(path) is a \(type)."]
        if let size {
            parts.append("Size: \(size).")
        }
        if let modified {
            parts.append("Modified: \(modified).")
        }
        return parts.joined(separator: " ")
    }

    func summarizeLastResult(_ result: String, context: ToolPresentationContext) -> ToolResultSnapshot? {
        guard let object = ToolModuleSupport.decodeObject(result) else {
            return nil
        }
        let path = object["path"]?.stringValue ?? "previous path"
        return ToolResultSnapshot(
            toolName: definition.name,
            domain: routingMetadata.domain,
            scopeSummary: "Previous file info lookup: \(path).",
            machineReadableScope: .object(["path": .string(path)])
        )
    }

    func normalizeArguments(_ rawArgumentsJSON: String, userInput: String, context: ToolExecutionContext) -> String {
        guard let decoded = ToolModuleSupport.decodeObject(rawArgumentsJSON) else {
            return rawArgumentsJSON
        }

        guard let path = decoded["path"]?.stringValue, path.isEmpty == false else {
            return "{}"
        }
        return #"{"path":"\#(escapeForJSON(path))"}"#
    }

    private func resolvePath(arguments: [String: JSONValue], userInput: String) throws -> String {
        if let path = arguments["path"]?.stringValue, path.isEmpty == false {
            return path
        }

        if let match = userInput.range(of: #"(~|/)[A-Za-z0-9_./-]+"#, options: .regularExpression) {
            return String(userInput[match])
        }

        throw AppError.message("Tool argument 'path' is required.")
    }

    private func escapeForJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct CalendarEventsToolModule: ToolModule {
    let definition: ToolDefinition
    let routingMetadata = ToolRoutingMetadata(domain: "calendar", supportsFollowUpReuse: true, followUpSummaryStyle: .timeframe)
    let supportsDeterministicFallbackInvocation = true
    private let calendarTools = CalendarTools()

    func execute(arguments: [String: JSONValue], userInput: String, context: ToolExecutionContext) async throws -> String {
        let timeframe = resolveTimeframe(arguments: arguments, userInput: userInput)
        let limit = ToolModuleSupport.resolveLimit(arguments: arguments, userInput: userInput, fallback: 10, upperBound: 20)
        return try await calendarTools.listEvents(timeframe: timeframe, limit: limit)
    }

    func summarizeResult(_ result: String, context: ToolPresentationContext) -> String? {
        guard
            let object = ToolModuleSupport.decodeObject(result),
            let timeframe = object["timeframe"]?.stringValue,
            let results = object["results"]?.arrayValue
        else {
            return nil
        }

        if results.isEmpty {
            return "You have no calendar events for \(timeframe)."
        }

        let lines = results.prefix(10).compactMap { item -> String? in
            guard let entry = item.objectValue,
                  let title = entry["title"]?.stringValue,
                  let start = entry["start"]?.stringValue,
                  let end = entry["end"]?.stringValue,
                  let calendar = entry["calendar"]?.stringValue
            else {
                return nil
            }

            var line = "- \(title) (\(calendar)) from \(Self.humanDate(start) ?? start) to \(Self.humanDate(end) ?? end)"
            if let location = entry["location"]?.stringValue {
                line += " at \(location)"
            }
            return line
        }

        guard lines.isEmpty == false else {
            return nil
        }

        return "You have \(lines.count) calendar event(s) for \(timeframe):\n" + lines.joined(separator: "\n")
    }

    func summarizeLastResult(_ result: String, context: ToolPresentationContext) -> ToolResultSnapshot? {
        guard let object = ToolModuleSupport.decodeObject(result) else {
            return nil
        }

        let timeframe = object["timeframe"]?.stringValue ?? "today"
        let count = object["results"]?.arrayValue?.count ?? 0
        var scope: [String: JSONValue] = [
            "timeframe": .string(timeframe),
            "returned_count": .number(Double(count)),
        ]
        if let absoluteDate = Self.absoluteDateString(for: timeframe, referenceDate: context.referenceDate, timeZone: context.timeZone) {
            scope["absolute_date"] = .string(absoluteDate)
        }

        let scopeSummary = "Previous calendar lookup covered \(timeframe)\(scope["absolute_date"]?.stringValue.map { " (\($0))" } ?? "") and returned \(count) event(s)."

        return ToolResultSnapshot(
            toolName: definition.name,
            domain: routingMetadata.domain,
            scopeSummary: scopeSummary,
            machineReadableScope: .object(scope)
        )
    }

    func normalizeArguments(_ rawArgumentsJSON: String, userInput: String, context: ToolExecutionContext) -> String {
        guard let decoded = ToolModuleSupport.decodeObject(rawArgumentsJSON) else {
            return rawArgumentsJSON
        }

        if let timeframe = decoded["timeframe"]?.stringValue, timeframe.isEmpty == false {
            if let limit = decoded["limit"]?.intValue {
                return #"{"timeframe":"\#(timeframe)","limit":\#(limit)}"#
            }
            return #"{"timeframe":"\#(timeframe)"}"#
        }

        if decoded["start_time"] != nil || decoded["end_time"] != nil || decoded["calendar"] != nil {
            return "{}"
        }

        return rawArgumentsJSON
    }

    private func resolveTimeframe(arguments: [String: JSONValue], userInput: String) -> String {
        if let timeframe = arguments["timeframe"]?.stringValue, timeframe.isEmpty == false {
            return timeframe
        }

        let input = userInput.lowercased()
        if input.contains("tomorrow") {
            return "tomorrow"
        }
        if input.contains("next 7") || input.contains("next seven") || input.contains("next week") {
            return "next_7_days"
        }
        return "today"
    }

    private static func absoluteDateString(for timeframe: String, referenceDate: Date, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        switch timeframe {
        case "today":
            return formatter.string(from: referenceDate)
        case "tomorrow":
            guard let date = calendar.date(byAdding: .day, value: 1, to: referenceDate) else {
                return nil
            }
            return formatter.string(from: date)
        case "next_7_days":
            let start = formatter.string(from: referenceDate)
            guard let endDate = calendar.date(byAdding: .day, value: 7, to: referenceDate) else {
                return nil
            }
            let end = formatter.string(from: endDate)
            return "\(start) through \(end)"
        default:
            return nil
        }
    }

    static func humanDate(_ isoString: String) -> String? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else {
            return nil
        }

        let output = DateFormatter()
        output.locale = Locale.autoupdatingCurrent
        output.timeZone = .autoupdatingCurrent
        output.dateStyle = .medium
        output.timeStyle = .short
        return output.string(from: date)
    }
}

private struct SafeCommandToolModule: ToolModule {
    let definition: ToolDefinition
    let routingMetadata = ToolRoutingMetadata(domain: "terminal", supportsFollowUpReuse: false, followUpSummaryStyle: .generic)
    private let terminalTools = TerminalTools()

    func execute(arguments: [String: JSONValue], userInput: String, context: ToolExecutionContext) async throws -> String {
        let command = try ToolModuleSupport.requireString(arguments["command"], key: "command")
        let suppliedArguments = arguments["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return try terminalTools.runSafeCommand(command: command, arguments: suppliedArguments)
    }

    func summarizeResult(_ result: String, context: ToolPresentationContext) -> String? {
        guard
            let object = ToolModuleSupport.decodeObject(result),
            let command = object["command"]?.stringValue,
            let stdout = object["stdout"]?.stringValue
        else {
            return nil
        }

        if stdout.isEmpty {
            return "\(command) completed with no output."
        }

        return "\(command) output:\n\(stdout)"
    }

    func summarizeLastResult(_ result: String, context: ToolPresentationContext) -> ToolResultSnapshot? {
        guard let object = ToolModuleSupport.decodeObject(result) else {
            return nil
        }
        let command = object["command"]?.stringValue ?? "previous command"
        return ToolResultSnapshot(
            toolName: definition.name,
            domain: routingMetadata.domain,
            scopeSummary: "Previous safe command: \(command).",
            machineReadableScope: .object(["command": .string(command)])
        )
    }

    func normalizeArguments(_ rawArgumentsJSON: String, userInput: String, context: ToolExecutionContext) -> String {
        guard let decoded = ToolModuleSupport.decodeObject(rawArgumentsJSON) else {
            return rawArgumentsJSON
        }

        if let command = decoded["command"]?.stringValue, command.isEmpty == false {
            let arguments = decoded["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let rendered = arguments.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"command":"\#(command)","arguments":[\#(rendered)]}"#
        }

        return rawArgumentsJSON
    }
}

private struct RecentMailToolModule: ToolModule {
    let definition: ToolDefinition
    let routingMetadata = ToolRoutingMetadata(domain: "mail", supportsFollowUpReuse: true, followUpSummaryStyle: .recentItems)
    let supportsDeterministicFallbackInvocation = true
    private let mailTools = MailTools()

    func execute(arguments: [String: JSONValue], userInput: String, context: ToolExecutionContext) async throws -> String {
        let limit = ToolModuleSupport.resolveLimit(arguments: arguments, userInput: userInput, fallback: 5, upperBound: 10)
        return try mailTools.listRecentMail(limit: limit)
    }

    func summarizeResult(_ result: String, context: ToolPresentationContext) -> String? {
        guard let snapshot = decodeRecentMail(result: result) else {
            return nil
        }

        if snapshot.messages.isEmpty {
            return "I could not find any recent messages in Apple Mail."
        }

        let lines = snapshot.messages.compactMap { message -> String? in
            let date = CalendarEventsToolModule.humanDate(message.dateReceived) ?? message.dateReceived
            return "- \(message.subject) from \(message.sender) at \(date)"
        }

        guard lines.isEmpty == false else {
            return nil
        }

        let requested = snapshot.requestedLimit
        return "Your recent \(requested == 1 ? "mail" : "\(requested) mails"):\n" + lines.joined(separator: "\n")
    }

    func summarizeLastResult(_ result: String, context: ToolPresentationContext) -> ToolResultSnapshot? {
        guard let snapshot = decodeRecentMail(result: result) else {
            return nil
        }

        let scope: [String: JSONValue] = [
            "requested_limit": .number(Double(snapshot.requestedLimit)),
            "returned_count": .number(Double(snapshot.returnedCount)),
            "mailbox": .string(snapshot.messages.first?.mailbox ?? "Mail"),
        ]

        return ToolResultSnapshot(
            toolName: definition.name,
            domain: routingMetadata.domain,
            scopeSummary: "Previous mail lookup returned \(snapshot.returnedCount) recent message(s) from \(snapshot.messages.first?.mailbox ?? "Mail").",
            machineReadableScope: .object(scope)
        )
    }

    func normalizeArguments(_ rawArgumentsJSON: String, userInput: String, context: ToolExecutionContext) -> String {
        guard let decoded = ToolModuleSupport.decodeObject(rawArgumentsJSON) else {
            return rawArgumentsJSON
        }

        if let limit = decoded["limit"]?.intValue {
            return #"{"limit":\#(limit)}"#
        }
        return "{}"
    }

    private func decodeRecentMail(result: String) -> MailToolSnapshot? {
        guard
            let object = ToolModuleSupport.decodeObject(result),
            let results = object["results"]?.arrayValue
        else {
            return nil
        }

        let messages = results.compactMap { item -> MailMessageSnapshot? in
            guard let entry = item.objectValue else {
                return nil
            }
            return MailMessageSnapshot(
                subject: entry["subject"]?.stringValue ?? "(no subject)",
                sender: entry["sender"]?.stringValue ?? "Unknown sender",
                dateReceived: entry["date_received"]?.stringValue ?? "",
                mailbox: entry["mailbox"]?.stringValue ?? "Mail"
            )
        }

        return MailToolSnapshot(
            requestedLimit: object["requested_limit"]?.intValue ?? messages.count,
            returnedCount: object["returned_count"]?.intValue ?? messages.count,
            messages: messages
        )
    }
}
