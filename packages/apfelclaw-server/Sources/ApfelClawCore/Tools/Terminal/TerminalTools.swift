import Foundation

public final class TerminalTools: Sendable {
    private let maxOutputCharacters = 4_000

    public init() {}

    public func runSafeCommand(command: String, arguments: [String]) throws -> String {
        guard let commandDefinition = SafeCommandRegistry.command(named: command) else {
            throw AppError.message("Command '\(command)' is not on the safe allowlist.")
        }

        try commandDefinition.validate(arguments: arguments)

        let result = try CommandRunner.run(executable: commandDefinition.executable, arguments: arguments, timeout: 8)
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(stderr.isEmpty ? "Command failed: \(command)" : stderr)
        }

        let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasTruncated = trimmedStdout.count > maxOutputCharacters
        let output = String(trimmedStdout.prefix(maxOutputCharacters))
        let payload: [String: JSONValue] = [
            "command": .string(command),
            "arguments": .array(arguments.map(JSONValue.string)),
            "stdout": .string(output),
            "stdout_characters_total": .number(Double(trimmedStdout.count)),
            "truncated": .bool(wasTruncated),
        ]
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }
}
