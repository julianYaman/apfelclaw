import Foundation

public enum FollowUpSummaryStyle: String, Sendable {
    case generic
    case timeframe
    case recentItems
}

public struct ToolRoutingMetadata: Sendable {
    public let domain: String
    public let supportsFollowUpReuse: Bool
    public let followUpSummaryStyle: FollowUpSummaryStyle

    public init(domain: String, supportsFollowUpReuse: Bool, followUpSummaryStyle: FollowUpSummaryStyle) {
        self.domain = domain
        self.supportsFollowUpReuse = supportsFollowUpReuse
        self.followUpSummaryStyle = followUpSummaryStyle
    }
}

public struct ToolExecutionContext: Sendable {
    public let referenceDate: Date
    public let timeZone: TimeZone

    public init(referenceDate: Date, timeZone: TimeZone) {
        self.referenceDate = referenceDate
        self.timeZone = timeZone
    }
}

public struct ToolPresentationContext: Sendable {
    public let referenceDate: Date
    public let timeZone: TimeZone

    public init(referenceDate: Date, timeZone: TimeZone) {
        self.referenceDate = referenceDate
        self.timeZone = timeZone
    }
}

public struct ToolResultSnapshot: Codable, Sendable {
    public let toolName: String
    public let domain: String
    public let scopeSummary: String
    public let machineReadableScope: JSONValue?

    public init(toolName: String, domain: String, scopeSummary: String, machineReadableScope: JSONValue?) {
        self.toolName = toolName
        self.domain = domain
        self.scopeSummary = scopeSummary
        self.machineReadableScope = machineReadableScope
    }
}

public protocol ToolModule: Sendable {
    var definition: ToolDefinition { get }
    var routingMetadata: ToolRoutingMetadata { get }
    var supportsDeterministicFallbackInvocation: Bool { get }
    func execute(arguments: [String: JSONValue], userInput: String, context: ToolExecutionContext) async throws -> String
    func summarizeResult(_ result: String, context: ToolPresentationContext) -> String?
    func summarizeLastResult(_ result: String, context: ToolPresentationContext) -> ToolResultSnapshot?
    func normalizeArguments(_ rawArgumentsJSON: String, userInput: String, context: ToolExecutionContext) -> String
}

public extension ToolModule {
    var supportsDeterministicFallbackInvocation: Bool { false }
}
