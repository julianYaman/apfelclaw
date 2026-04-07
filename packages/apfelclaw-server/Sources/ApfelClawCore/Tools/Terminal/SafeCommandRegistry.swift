import Foundation

public struct SafeCommand: Sendable {
    public let name: String
    public let purpose: String
}

public enum SafeCommandRegistry {
    public static let commands: [SafeCommand] = [
        SafeCommand(name: "pwd", purpose: "Show the current working directory"),
        SafeCommand(name: "ls", purpose: "List files in a directory"),
        SafeCommand(name: "whoami", purpose: "Show the current user name"),
        SafeCommand(name: "date", purpose: "Show the current date and time"),
        SafeCommand(name: "mdfind", purpose: "Search indexed files with Spotlight"),
        SafeCommand(name: "mdls", purpose: "Read Spotlight metadata for a file"),
        SafeCommand(name: "stat", purpose: "Read file metadata"),
        SafeCommand(name: "find", purpose: "Search the filesystem without Spotlight"),
        SafeCommand(name: "ps", purpose: "List running processes"),
        SafeCommand(name: "lsof", purpose: "List open files and ports"),
    ]
}
