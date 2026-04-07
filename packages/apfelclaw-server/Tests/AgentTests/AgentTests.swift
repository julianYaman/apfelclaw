import Foundation
import Testing
@testable import ApfelClawCore

private let routerReferenceDate = ISO8601DateFormatter().date(from: "2026-04-07T11:49:54+02:00")!
private let routerTimeZone = TimeZone(secondsFromGMT: 7_200)!

@Test
func approvalModeLabelsExist() {
    #expect(ApprovalMode.allCases.count == 3)
    #expect(ApprovalMode.always.label.isEmpty == false)
}

@Test
func intentRouterPicksToolFromModelClassification() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [#"{"action":"use_tool","toolName":"list_recent_mail","reasonCode":"fresh_personal_data"}"#]
    )

    let decision = try await IntentRouter.route(
        messages: [("user", "Show me my most recent email.")],
        userInput: "Show me my most recent email.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_recent_mail")
    #expect(decision.reasonCode == .freshPersonalData)
}

@Test
func intentRouterFallsBackToDirectAnswerWhenClassifierSaysNoTool() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [#"{"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}"#]
    )

    let decision = try await IntentRouter.route(
        messages: [("user", "What is your version?")],
        userInput: "What is your version?",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .answerDirectly)
    #expect(decision.toolName == nil)
    #expect(decision.reasonCode == .directAnswerOK)
}

@Test
func intentRouterReusesCalendarToolForShortFollowUp() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [#"{"action":"use_tool","toolName":"list_calendar_events","reasonCode":"same_domain_follow_up"}"#]
    )
    let lastToolCall = ToolCallRecord(
        toolName: "list_calendar_events",
        approved: true,
        payload: #"{"arguments":"{}","result":"{\"timeframe\":\"today\",\"results\":[]}"}"#,
        createdAt: "2026-04-07T10:00:00Z"
    )

    let decision = try await IntentRouter.route(
        messages: [
            ("user", "What are my events for today?"),
            ("assistant", "You have 2 calendar event(s) for today:")
        ],
        userInput: "And for tomorrow?",
        lastToolCall: lastToolCall,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_calendar_events")
    #expect(decision.reasonCode == .sameDomainFollowUp)
}

@Test
func classifierPromptIncludesCompactRoutingContext() throws {
    let runtime = try ToolRuntime()
    let lastToolCall = ToolCallRecord(
        toolName: "list_calendar_events",
        approved: true,
        payload: #"{"arguments":"{}","result":"{\"timeframe\":\"today\",\"results\":[]}"}"#,
        createdAt: "2026-04-07T10:00:00Z"
    )

    let messages = IntentRouter.buildClassifierMessages(
        messages: [
            ("user", "What are my events for today?"),
            ("assistant", "You have 2 calendar event(s) for today:")
        ],
        userInput: "And for tomorrow?",
        lastToolCall: lastToolCall,
        toolRegistry: runtime.registry,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(messages.count == 2)
    #expect(messages[0].content?.contains("You are not the assistant. You are the router for apfelclaw.") == true)
    #expect(messages[0].content?.contains("Allowed action values: use_tool, answer_directly") == true)
    #expect(messages[0].content?.contains("Allowed reasonCode values: fresh_personal_data, same_domain_follow_up, prior_result_insufficient, direct_answer_ok, other") == true)
    #expect(messages[0].content?.contains("Small-model rule:") == true)
    #expect(messages[0].content?.contains(#"- "Hello." -> {"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}"#) == true)
    #expect(messages[0].content?.contains("When in doubt between answer_directly and use_tool") == true)
    #expect(messages[0].content?.contains("Never emit function calls or tool_calls.") == true)
    #expect(messages[0].content?.contains("domain: calendar") == true)
    #expect(messages[1].content?.contains("toolName: list_calendar_events") == true)
    #expect(messages[1].content?.contains("scopeSummary: Previous calendar lookup covered today") == true)
    #expect(messages[1].content?.contains(#""timeframe":"today""#) == true)
}

@Test
func strictClassifierPromptCallsOutRetryAfterInvalidOutput() throws {
    let runtime = try ToolRuntime()

    let messages = IntentRouter.buildClassifierMessages(
        messages: [("user", "Show me my recent emails.")],
        userInput: "Show me my recent emails.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone,
        strict: true
    )

    #expect(messages[0].content?.contains("Previous output was invalid. Retry and return exactly one JSON object matching the schema.") == true)
}

@Test
func directAnswerVerificationPromptPrefersToolWhenOneFits() throws {
    let runtime = try ToolRuntime()

    let messages = IntentRouter.buildDirectAnswerVerificationMessages(
        messages: [("user", "Show me my recent emails.")],
        userInput: "Show me my recent emails.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(messages[0].content?.contains("This is a narrow check for a small model") == true)
    #expect(messages[0].content?.contains("Most messages should return null.") == true)
    #expect(messages[0].content?.contains(#"- "Hello." -> {"toolName":null,"reasonCode":"direct_answer_ok"}"#) == true)
    #expect(messages[0].content?.contains("should return a matching tool, not null") == true)
    #expect(messages[0].content?.contains("examples: Please show me my recent emails | Show me my most recent email | What emails arrived recently?") == true)
}

@Test
func classifierPromptIncludesToolSpecificGuidanceForDisambiguation() throws {
    let runtime = try ToolRuntime()

    let messages = IntentRouter.buildClassifierMessages(
        messages: [
            ("user", "What is in my calendar for tomorrow?"),
            ("assistant", "You have 3 events tomorrow.")
        ],
        userInput: "Where are my events?",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(messages.count == 2)
    #expect(messages[0].content?.contains("use_when: The user asks where a file is, wants to locate a document, or needs matching file paths.") == true)
    #expect(messages[0].content?.contains("examples: Please show me my calendar events for today | What meetings do I have today? | Show my calendar for tomorrow") == true)
}

@Test
func toolDescriptionsIncludeGuidanceMetadata() {
    let runtime = try! ToolRuntime()
    let mailTool = runtime.availableTools.first { $0.name == "list_recent_mail" }!

    #expect(mailTool.summary.contains("most recent messages"))
    #expect(mailTool.description.contains("Use when:"))
    #expect(mailTool.description.contains("Avoid when:"))
    #expect(mailTool.description.contains("Examples:"))
    #expect(mailTool.description.contains("Returns:"))
}

@Test
func structuredMailResultsFormatLocally() {
    let runtime = try! ToolRuntime()
    let mailTool = runtime.availableTools.first { $0.name == "list_recent_mail" }!
    let result = """
    {"mailbox":"All Inboxes","requested_limit":1,"returned_count":1,"results":[{"subject":"Build finished","sender":"CI <ci@example.com>","date_received":"2026-04-06T13:42:22.000Z","mailbox":"All Inboxes"}]}
    """

    let formatted = ToolResultFormatter.format(result: result, for: mailTool)

    #expect(formatted?.contains("Build finished") == true)
    #expect(formatted?.contains("CI <ci@example.com>") == true)
    #expect(formatted?.contains("Your recent mail:") == true)
}

@Test
func systemPromptIncludesReferenceTimeForRelativeDates() {
    let formatter = ISO8601DateFormatter()
    let date = formatter.date(from: "2026-04-06T12:00:00Z")!
    let timeZone = TimeZone(secondsFromGMT: 7_200)!

    let prompt = ConversationService.systemPrompt(
        assistantName: "Apfelclaw",
        now: date,
        timeZone: timeZone
    )

    #expect(prompt.contains("Reference time for this request:"))
    #expect(prompt.contains("Backend version: \(AppVersion.current)."))
    #expect(prompt.contains("2026-04-06T14:00:00+02:00"))
    #expect(prompt.contains("today"))
    #expect(prompt.contains("relative time phrases"))
}

@Test
func toolCallPromptLocksToSelectedTool() throws {
    let runtime = try ToolRuntime()
    let selectedTool = try #require(runtime.definition(named: "list_calendar_events"))
    let formatter = ISO8601DateFormatter()
    let date = formatter.date(from: "2026-04-06T12:00:00Z")!
    let timeZone = TimeZone(secondsFromGMT: 7_200)!

    let prompt = ConversationService.toolCallSystemPrompt(
        assistantName: "Apfelclaw",
        selectedTool: selectedTool,
        now: date,
        timeZone: timeZone
    )

    #expect(prompt.contains(#"The router already selected the tool "list_calendar_events""#))
    #expect(prompt.contains("Never choose a different tool name."))
    #expect(prompt.contains("If required information is missing, ask one short clarification question"))
}

@Test
func modelClientNormalizesSafeCommandToolNames() {
    let toolCall = ChatToolCall(
        id: "call_1",
        type: "function",
        function: .init(name: "date", arguments: "\"\"")
    )

    let normalized = ModelClient.normalizeToolCall(toolCall)

    #expect(normalized.name == "run_safe_command")
    #expect(normalized.argumentsJSON == #"{"command":"date","arguments":[]}"#)
}

@Test
func modelClientExtractsFallbackToolCallFromFencedJSON() {
    let content = """
    ```json
    {"tool_calls":[{"id":"call_1","type":"function","function":{"name":"date","arguments":"\\"\\\""}}]}
    ```
    """

    let toolCall = ModelClient.extractToolCall(from: content)

    #expect(toolCall?.name == "run_safe_command")
    #expect(toolCall?.argumentsJSON == #"{"command":"date","arguments":[]}"#)
}

@Test
func modelClientExtractsMalformedCalendarToolCallFromFencedJSON() {
    let content = """
    ```json
    {"tool_calls":[{"id":"call_1","type":"function","function":{"name":"list_calendar_events","arguments":"{\\"start_time\\":\\"2026-04-06T17:52:07+02:00\\",\\"end_time\\":\\"2026-04-06T23:59:59+02:00\\",\\"calendar\\":\\"personal\\"}"}}]}
    ```
    """

    let toolCall = ModelClient.extractToolCall(from: content)

    #expect(toolCall?.name == "list_calendar_events")
    #expect(toolCall?.argumentsJSON == #"{}"#)
}

@Test
func intentRouterRecoversToolUseWhenPriorToolDidNotCoverNewScope() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [
            #"{"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}"#,
            #"{"reuseLastTool":true,"reasonCode":"prior_result_insufficient"}"#
        ]
    )
    let lastToolCall = ToolCallRecord(
        toolName: "list_calendar_events",
        approved: true,
        payload: #"{"arguments":"{\"timeframe\":\"today\"}","result":"{\"timeframe\":\"today\",\"results\":[]}"}"#,
        createdAt: "2026-04-07T10:00:00Z"
    )

    let decision = try await IntentRouter.route(
        messages: [
            ("user", "What are my events for today?"),
            ("assistant", "You have no calendar event(s) for today."),
        ],
        userInput: "And for tomorrow?",
        lastToolCall: lastToolCall,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_calendar_events")
    #expect(decision.reasonCode == .priorResultInsufficient)
}

@Test
func intentRouterRetriesInvalidClassifierOutputBeforeFallingBack() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [
            #"{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"list_recent_mail","arguments":"{}"}}]}"#,
            #"{"action":"use_tool","toolName":"list_recent_mail","reasonCode":"fresh_personal_data"}"#,
        ]
    )

    let decision = try await IntentRouter.route(
        messages: [("user", "Show me my recent emails.")],
        userInput: "Show me my recent emails.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_recent_mail")
    #expect(decision.reasonCode == .freshPersonalData)
    #expect(decision.debugTrace?.contains(#""stage":"classifier""#) == true)
    #expect(decision.debugTrace?.contains(#""status":"invalid_json""#) == true)
    #expect(decision.debugTrace?.contains(#""status":"accepted""#) == true)
    #expect(await model.recordedModes() == [.textOnly, .textOnly])
}

@Test
func intentRouterRejectsAnswerDirectlyWithFollowUpReasonCode() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [
            #"{"action":"answer_directly","toolName":null,"reasonCode":"same_domain_follow_up"}"#,
            #"{"action":"use_tool","toolName":"list_calendar_events","reasonCode":"fresh_personal_data"}"#,
        ]
    )

    let decision = try await IntentRouter.route(
        messages: [("user", "What is on my calendar for today?")],
        userInput: "What is on my calendar for today?",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_calendar_events")
    #expect(decision.reasonCode == .freshPersonalData)
    #expect(await model.recordedModes() == [.textOnly, .textOnly])
}

@Test
func intentRouterVerifiesAcceptedDirectAnswerBeforeKeepingIt() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [
            #"{"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}"#,
            #"{"action":"use_tool","toolName":"list_recent_mail","reasonCode":"fresh_personal_data"}"#,
        ]
    )

    let decision = try await IntentRouter.route(
        messages: [("user", "Show me my recent emails.")],
        userInput: "Show me my recent emails.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_recent_mail")
    #expect(decision.reasonCode == .freshPersonalData)
    #expect(decision.debugTrace?.contains(#""stage":"direct_answer_check""#) == true)
    #expect(await model.recordedModes() == [.textOnly, .textOnly])
}

@Test
func intentRouterAcceptsToolOverrideWhenReasonCodeIsWrong() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [
            #"{"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}"#,
            #"{"toolName":"list_recent_mail","reasonCode":"direct_answer_ok"}"#,
        ]
    )

    let decision = try await IntentRouter.route(
        messages: [("user", "Show me my recent emails.")],
        userInput: "Show me my recent emails.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_recent_mail")
    #expect(decision.reasonCode == .freshPersonalData)
}

@Test
func intentRouterKeepsGreetingAsDirectAnswerWhenVerifierReturnsNull() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [
            #"{"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}"#,
            #"{"toolName":null,"reasonCode":"direct_answer_ok"}"#,
        ]
    )

    let decision = try await IntentRouter.route(
        messages: [("user", "Hello.")],
        userInput: "Hello.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .answerDirectly)
    #expect(decision.toolName == nil)
    #expect(decision.reasonCode == .directAnswerOK)
}

@Test
func intentRouterRecoversFollowUpReuseFromPipeSeparatedReasonCode() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(
        responses: [
            #"{"action":"answer_directly","toolName":null,"reasonCode":"direct_answer_ok"}"#,
            #"{"reuseLastTool":true,"reasonCode":"same_domain_follow_up|prior_result_insufficient"}"#,
        ]
    )
    let lastToolCall = ToolCallRecord(
        toolName: "list_recent_mail",
        approved: true,
        payload: #"{"arguments":"{}","result":"{\"mailbox\":\"All Inboxes\",\"requested_limit\":5,\"returned_count\":2,\"results\":[]}"}"#,
        createdAt: "2026-04-07T10:00:00Z"
    )

    let decision = try await IntentRouter.route(
        messages: [
            ("user", "Show me my recent emails."),
            ("assistant", "Your recent 5 mails:")
        ],
        userInput: "Can you try again?",
        lastToolCall: lastToolCall,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .useTool)
    #expect(decision.toolName == "list_recent_mail")
    #expect(decision.reasonCode == .sameDomainFollowUp)
}

@Test
func intentRouterUsesOtherReasonWhenClassifierRemainsInvalid() async throws {
    let runtime = try ToolRuntime()
    let model = StubModelClient(responses: ["not json", "still not json"])

    let decision = try await IntentRouter.route(
        messages: [("user", "Show me my recent emails.")],
        userInput: "Show me my recent emails.",
        lastToolCall: nil,
        toolRegistry: runtime.registry,
        modelClient: model,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(decision.action == .answerDirectly)
    #expect(decision.toolName == nil)
    #expect(decision.reasonCode == .other)
    #expect(await model.recordedModes() == [.textOnly, .textOnly])
}

@Test
func followUpVerifierDoesNotReuseMailWhenDomainSwitches() throws {
    let runtime = try ToolRuntime()
    let lastToolCall = ToolCallRecord(
        toolName: "list_recent_mail",
        approved: true,
        payload: #"{"arguments":"{}","result":"{\"mailbox\":\"All Inboxes\",\"requested_limit\":5,\"returned_count\":2,\"results\":[]}"}"#,
        createdAt: "2026-04-07T10:00:00Z"
    )

    let messages = IntentRouter.buildFollowUpVerificationMessages(
        messages: [
            ("user", "Show my latest emails."),
            ("assistant", "Your recent mail:")
        ],
        userInput: "Find notes.md",
        lastToolCall: lastToolCall,
        toolRegistry: runtime.registry,
        referenceDate: routerReferenceDate,
        timeZone: routerTimeZone
    )

    #expect(messages[0].content?.contains("You are checking whether the user's latest message continues the previous tool-backed request.") == true)
    #expect(messages[1].content?.contains("toolName: list_recent_mail") == true)
    #expect(messages[1].content?.contains("Previous mail lookup returned") == true)
}

@Test
func toolRegistryExposesRegisteredModules() throws {
    let runtime = try ToolRuntime()

    #expect(runtime.registry.modules.count == runtime.availableTools.count)
    #expect(runtime.registry.module(named: "list_calendar_events")?.routingMetadata.domain == "calendar")
    #expect(runtime.registry.module(named: "run_safe_command")?.routingMetadata.domain == "terminal")
}

@Test
func toolRuntimeOnlyProvidesDeterministicFallbackForSupportedTools() throws {
    let runtime = try ToolRuntime()

    #expect(runtime.deterministicFallbackToolCall(named: "list_calendar_events")?.name == "list_calendar_events")
    #expect(runtime.deterministicFallbackToolCall(named: "list_recent_mail")?.name == "list_recent_mail")
    #expect(runtime.deterministicFallbackToolCall(named: "find_files") == nil)
    #expect(runtime.deterministicFallbackToolCall(named: "get_file_info") == nil)
}

private actor StubModelResponses {
    private var responses: [String]
    private var modes: [CompletionMode] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    func next(mode: CompletionMode) -> String? {
        modes.append(mode)
        guard responses.isEmpty == false else {
            return nil
        }
        return responses.removeFirst()
    }

    func recordedModes() -> [CompletionMode] {
        modes
    }
}

private final class StubModelClient: ModelCompleting, @unchecked Sendable {
    let responses: StubModelResponses
    let toolCall: ToolCall?

    init(responses: [String], toolCall: ToolCall? = nil) {
        self.responses = StubModelResponses(responses)
        self.toolCall = toolCall
    }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], mode: CompletionMode) async throws -> CompletionOutcome {
        if let text = await responses.next(mode: mode) {
            return CompletionOutcome(text: text, toolCall: toolCall)
        }
        return CompletionOutcome(text: nil, toolCall: toolCall)
    }

    func recordedModes() async -> [CompletionMode] {
        await responses.recordedModes()
    }
}
