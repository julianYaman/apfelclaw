import Foundation
import Testing
@testable import ApfelClawCore

@Test
func trustedReadonlySkipsPromptsForReadonlyToolWithoutConfirmation() {
    let policy = ToolPolicy(approvalMode: .trustedReadonly)
    let tool = makeTool(name: "readonly_tool", readonly: true, requiresConfirmation: false)

    #expect(policy.requiresPrompt(for: tool, priorApprovalExists: false) == false)
}

@Test
func trustedReadonlyStillPromptsForExplicitConfirmationTools() {
    let policy = ToolPolicy(approvalMode: .trustedReadonly)
    let tool = makeTool(name: "confirmed_tool", readonly: true, requiresConfirmation: true)

    #expect(policy.requiresPrompt(for: tool, priorApprovalExists: false) == true)
}

@Test
func askOncePerToolPerSessionSkipsPromptAfterApproval() {
    let policy = ToolPolicy(approvalMode: .askOncePerToolPerSession)
    let tool = makeTool(name: "readonly_tool", readonly: true, requiresConfirmation: false)

    #expect(policy.requiresPrompt(for: tool, priorApprovalExists: false) == true)
    #expect(policy.requiresPrompt(for: tool, priorApprovalExists: true) == false)
}

@Test
func runtimeRejectsMissingFindFilesQuery() async throws {
    let runtime = try ToolRuntime()

    do {
        _ = try await runtime.execute(
            toolCall: ToolCall(id: "call_1", name: "find_files", argumentsJSON: "{}"),
            userInput: "Find notes.md",
            context: ToolExecutionContext(referenceDate: Date(), timeZone: .current)
        )
        Issue.record("Expected missing query validation to fail.")
    } catch is AppError {
    }
}

@Test
func runtimeRejectsUnsupportedMailArguments() async throws {
    let runtime = try ToolRuntime()

    do {
        _ = try await runtime.execute(
            toolCall: ToolCall(id: "call_1", name: "list_recent_mail", argumentsJSON: #"{"sender":"ci@example.com"}"#),
            userInput: "Show mail from CI",
            context: ToolExecutionContext(referenceDate: Date(), timeZone: .current)
        )
        Issue.record("Expected unsupported mail arguments to fail.")
    } catch is AppError {
    }
}

@Test
func runtimeAcceptsCalendarTimeRangeAlias() async throws {
    let runtime = try ToolRuntime()
    let module = try #require(runtime.module(named: "list_calendar_events"))

    let arguments = try module.validatedArguments(from: #"{"time_range":"today"}"#)

    #expect(arguments["timeframe"]?.stringValue == "today")
    #expect(arguments["time_range"] == nil)
}

@Test
func macStatusToolRejectsUnsupportedSections() throws {
    let runtime = try ToolRuntime()
    let module = try #require(runtime.module(named: "get_mac_status"))

    do {
        _ = try module.validatedArguments(from: #"{"sections":["battery","cpu"]}"#)
        Issue.record("Expected unsupported Mac status sections to fail.")
    } catch is AppError {
    }
}

@Test
func macStatusToolDeduplicatesSections() throws {
    let runtime = try ToolRuntime()
    let module = try #require(runtime.module(named: "get_mac_status"))

    let arguments = try module.validatedArguments(from: #"{"sections":["battery","memory","battery"]}"#)

    #expect(arguments["sections"]?.arrayValue?.count == 2)
    #expect(arguments["sections"]?.arrayValue?.first?.stringValue == "battery")
    #expect(arguments["sections"]?.arrayValue?.last?.stringValue == "memory")
}

@Test
func macStatusSummaryFormatsOverviewPayload() throws {
    let runtime = try ToolRuntime()
    let module = try #require(runtime.module(named: "get_mac_status"))

    let result = #"{"requested_sections":["battery","thermal","uptime"],"battery":{"has_battery":true,"percentage":84,"is_charging":false,"time_remaining_minutes":132},"thermal":{"state":"nominal"},"uptime":{"seconds":98765,"human_readable":"1 day, 3 hours"}}"#

    let summary = module.summarizeResult(
        result,
        context: ToolPresentationContext(referenceDate: Date(), timeZone: .current)
    )

    #expect(summary?.contains("Battery at 84%") == true)
    #expect(summary?.contains("Thermal state is nominal.") == true)
    #expect(summary?.contains("System uptime: 1 day, 3 hours.") == true)
}

@Test
func macStatusSnapshotTracksRequestedSections() throws {
    let runtime = try ToolRuntime()
    let module = try #require(runtime.module(named: "get_mac_status"))

    let result = #"{"requested_sections":["storage","uptime"],"storage":{"path":"/","total_bytes":1000,"free_bytes":400},"uptime":{"seconds":3600,"human_readable":"1 hour"}}"#

    let snapshot = module.summarizeLastResult(
        result,
        context: ToolPresentationContext(referenceDate: Date(), timeZone: .current)
    )

    #expect(snapshot?.domain == "system")
    #expect(snapshot?.scopeSummary.contains("storage, uptime") == true)
    #expect(snapshot?.machineReadableScope?.objectValue?["sections"]?.arrayValue?.count == 2)
}

@Test
func calendarToolsResolveNaturalLanguageTimeframes() throws {
    let tools = CalendarTools()
    let formatter = ISO8601DateFormatter()
    let referenceDate = try #require(formatter.date(from: "2026-04-07T11:49:54+02:00"))
    let timeZone = try #require(TimeZone(secondsFromGMT: 7_200))

    let resolved = try tools.resolveTimeframe("April 12, 2026", referenceDate: referenceDate, timeZone: timeZone)

    #expect(resolved.label == "April 12, 2026")
    #expect(resolved.start < resolved.end)
}

@Test
func safeCommandRegistryRejectsUnsupportedArguments() throws {
    let date = try #require(SafeCommandRegistry.command(named: "date"))

    do {
        try date.validate(arguments: ["-u"])
        Issue.record("Expected unsupported date arguments to fail.")
    } catch is AppError {
    }
}

@Test
func safeCommandRegistryAllowsSpotlightQueriesWithSpaces() throws {
    let mdfind = try #require(SafeCommandRegistry.command(named: "mdfind"))

    try mdfind.validate(arguments: ["project proposal"])
}

private func makeTool(name: String, readonly: Bool, requiresConfirmation: Bool) -> ToolDefinition {
    ToolDefinition(
        entry: ToolManifestEntry(
            name: name,
            description: "Test tool",
            readonly: readonly,
            requiresConfirmation: requiresConfirmation,
            resultFormat: "test",
            useWhen: nil,
            avoidWhen: nil,
            examples: nil,
            returns: nil,
            parameters: .object(["type": .string("object")])
        )
    )
}
