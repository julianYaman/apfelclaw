import Foundation

public enum ToolResultFormatter {
    public static func format(result: String, for tool: ToolDefinition) -> String? {
        guard let module = try? ToolRegistry().module(named: tool.name) else {
            return nil
        }
        return module.summarizeResult(
            result,
            context: ToolPresentationContext(referenceDate: Date(), timeZone: .autoupdatingCurrent)
        )
    }
}
