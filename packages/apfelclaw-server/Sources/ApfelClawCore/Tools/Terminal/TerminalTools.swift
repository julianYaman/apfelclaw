import Foundation

public final class TerminalTools: Sendable {
    private let executables: [String: String] = [
        "pwd": "/bin/pwd",
        "ls": "/bin/ls",
        "whoami": "/usr/bin/whoami",
        "date": "/bin/date",
        "mdfind": "/usr/bin/mdfind",
        "mdls": "/usr/bin/mdls",
        "stat": "/usr/bin/stat",
        "find": "/usr/bin/find",
        "ps": "/bin/ps",
        "lsof": "/usr/sbin/lsof",
    ]

    public init() {}

    public func runSafeCommand(command: String, arguments: [String]) throws -> String {
        guard let executable = executables[command] else {
            throw AppError.message("Command '\(command)' is not on the safe allowlist.")
        }

        for argument in arguments {
            guard Self.isSafe(argument: argument) else {
                throw AppError.message("Command argument contains unsupported characters: \(argument)")
            }
        }

        let result = try CommandRunner.run(executable: executable, arguments: arguments, timeout: 8)
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(stderr.isEmpty ? "Command failed: \(command)" : stderr)
        }

        let output = String(result.stdout.prefix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: JSONValue] = [
            "command": .string(command),
            "arguments": .array(arguments.map(JSONValue.string)),
            "stdout": .string(output),
        ]
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func isSafe(argument: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: #"^[A-Za-z0-9_./:=,+@%-]+$"#)
        let range = NSRange(argument.startIndex..<argument.endIndex, in: argument)
        return regex?.firstMatch(in: argument, range: range) != nil
    }
}
