import Foundation

public enum SafeCommandArgumentPolicy: Sendable {
    case none
    case listDirectory
    case spotlightSearch
    case spotlightMetadata
    case fileMetadata
    case filesystemSearch
    case processes
    case openFiles
}

public struct SafeCommand: Sendable {
    public let name: String
    public let purpose: String
    public let executable: String
    public let argumentPolicy: SafeCommandArgumentPolicy

    public func validate(arguments: [String]) throws {
        try SafeCommandRegistry.validateRawArguments(arguments, for: name)

        switch argumentPolicy {
        case .none:
            guard arguments.isEmpty else {
                throw AppError.message("Command '\(name)' does not accept arguments.")
            }
        case .listDirectory:
            guard arguments.count <= 4 else {
                throw AppError.message("Command '\(name)' accepts at most 4 arguments.")
            }
            let allowedFlags: Set<String> = ["-1", "-a", "-al", "-h", "-l", "-la", "-lah"]
            try SafeCommandRegistry.validateFlagsAndValues(arguments, allowedFlags: allowedFlags, command: name)
        case .spotlightSearch:
            guard arguments.count == 1 || arguments.count == 3 else {
                throw AppError.message("Command '\(name)' expects a query, or '-onlyin <path> <query>'.")
            }
            if arguments.count == 3 {
                guard arguments[0] == "-onlyin", SafeCommandRegistry.isValueArgument(arguments[1]) else {
                    throw AppError.message("Command '\(name)' only supports '-onlyin <path> <query>'.")
                }
            }
        case .spotlightMetadata:
            guard arguments.count == 1 || arguments.count == 3 else {
                throw AppError.message("Command '\(name)' expects '<path>' or '-name <attribute> <path>'.")
            }
            if arguments.count == 3 {
                guard arguments[0] == "-name", SafeCommandRegistry.isValueArgument(arguments[1]), SafeCommandRegistry.isValueArgument(arguments[2]) else {
                    throw AppError.message("Command '\(name)' only supports '-name <attribute> <path>'.")
                }
            } else if SafeCommandRegistry.isValueArgument(arguments[0]) == false {
                throw AppError.message("Command '\(name)' expects a file path.")
            }
        case .fileMetadata:
            guard arguments.count == 1, SafeCommandRegistry.isValueArgument(arguments[0]) else {
                throw AppError.message("Command '\(name)' expects exactly one file path.")
            }
        case .filesystemSearch:
            guard arguments.count == 1 || arguments.count == 3 else {
                throw AppError.message("Command '\(name)' expects '<path>' or '<path> -name <pattern>'.")
            }
            guard SafeCommandRegistry.isValueArgument(arguments[0]) else {
                throw AppError.message("Command '\(name)' expects the first argument to be a search path.")
            }
            if arguments.count == 3 {
                guard arguments[1] == "-name", SafeCommandRegistry.isValueArgument(arguments[2]) else {
                    throw AppError.message("Command '\(name)' only supports '<path> -name <pattern>'.")
                }
            }
        case .processes:
            let allowedForms: Set<[String]> = [[], ["-ax"], ["aux"]]
            guard allowedForms.contains(arguments) else {
                throw AppError.message("Command '\(name)' only supports no arguments, '-ax', or 'aux'.")
            }
        case .openFiles:
            let allowedForms: Set<[String]> = [[], ["-i"]]
            if allowedForms.contains(arguments) {
                return
            }
            guard arguments.count == 2, arguments[0] == "-p", Int(arguments[1]) != nil else {
                throw AppError.message("Command '\(name)' only supports no arguments, '-i', or '-p <pid>'.")
            }
        }
    }
}

public enum SafeCommandRegistry {
    public static let commands: [SafeCommand] = [
        SafeCommand(name: "pwd", purpose: "Show the current working directory", executable: "/bin/pwd", argumentPolicy: .none),
        SafeCommand(name: "ls", purpose: "List files in a directory", executable: "/bin/ls", argumentPolicy: .listDirectory),
        SafeCommand(name: "whoami", purpose: "Show the current user name", executable: "/usr/bin/whoami", argumentPolicy: .none),
        SafeCommand(name: "date", purpose: "Show the current date and time", executable: "/bin/date", argumentPolicy: .none),
        SafeCommand(name: "mdfind", purpose: "Search indexed files with Spotlight", executable: "/usr/bin/mdfind", argumentPolicy: .spotlightSearch),
        SafeCommand(name: "mdls", purpose: "Read Spotlight metadata for a file", executable: "/usr/bin/mdls", argumentPolicy: .spotlightMetadata),
        SafeCommand(name: "stat", purpose: "Read file metadata", executable: "/usr/bin/stat", argumentPolicy: .fileMetadata),
        SafeCommand(name: "find", purpose: "Search the filesystem without Spotlight", executable: "/usr/bin/find", argumentPolicy: .filesystemSearch),
        SafeCommand(name: "ps", purpose: "List running processes", executable: "/bin/ps", argumentPolicy: .processes),
        SafeCommand(name: "lsof", purpose: "List open files and ports", executable: "/usr/sbin/lsof", argumentPolicy: .openFiles),
    ]

    public static func command(named name: String) -> SafeCommand? {
        commands.first { $0.name == name }
    }

    static func validateRawArguments(_ arguments: [String], for command: String) throws {
        for argument in arguments {
            guard argument.isEmpty == false else {
                throw AppError.message("Command '\(command)' does not accept empty arguments.")
            }

            let containsUnsafeCharacters = argument.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar) || "|&;<>`".unicodeScalars.contains(scalar)
            }
            if containsUnsafeCharacters {
                throw AppError.message("Command '\(command)' received an unsafe argument: \(argument)")
            }
        }
    }

    static func validateFlagsAndValues(_ arguments: [String], allowedFlags: Set<String>, command: String) throws {
        for argument in arguments {
            if argument.hasPrefix("-") {
                guard allowedFlags.contains(argument) else {
                    throw AppError.message("Command '\(command)' does not allow the flag '\(argument)'.")
                }
            } else if isValueArgument(argument) == false {
                throw AppError.message("Command '\(command)' received an invalid argument: \(argument)")
            }
        }
    }

    static func isValueArgument(_ argument: String) -> Bool {
        argument.hasPrefix("-") == false
    }
}
