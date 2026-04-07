import Foundation

public enum ToolResultInterpreter {
    public static func snapshot(
        from result: String,
        for tool: ToolDefinition,
        referenceDate: Date,
        timeZone: TimeZone
    ) -> ToolResultSnapshot? {
        guard let module = try? ToolRegistry().module(named: tool.name) else {
            return nil
        }
        return module.summarizeLastResult(
            result,
            context: ToolPresentationContext(referenceDate: referenceDate, timeZone: timeZone)
        )
    }
}
