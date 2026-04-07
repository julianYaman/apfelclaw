import Foundation

public final class FileTools: Sendable {
    public init() {}

    public func findFiles(query: String, limit: Int) throws -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            throw AppError.message("File search query cannot be empty.")
        }

        let command = try CommandRunner.run(
            executable: "/usr/bin/mdfind",
            arguments: [trimmedQuery],
            timeout: 8
        )

        guard command.exitCode == 0 else {
            throw AppError.message(command.stderr.isEmpty ? "mdfind failed." : command.stderr)
        }

        let paths = command.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.isEmpty == false }
            .prefix(limit)

        let results = paths.map { path in
            let url = URL(fileURLWithPath: path)
            return JSONValue.object([
                "path": .string(path),
                "name": .string(url.lastPathComponent),
            ])
        }

        return try encode([
            "query": .string(trimmedQuery),
            "results": .array(Array(results)),
        ])
    }

    public func getFileInfo(path: String) throws -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: expandedPath)
        guard exists else {
            throw AppError.message("Path does not exist: \(expandedPath)")
        }

        let url = URL(fileURLWithPath: expandedPath)
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .localizedTypeDescriptionKey,
        ])

        var object: [String: JSONValue] = [
            "path": .string(expandedPath),
            "name": .string(url.lastPathComponent),
            "is_directory": .bool(values.isDirectory ?? false),
        ]

        if let typeDescription = values.localizedTypeDescription {
            object["type_description"] = .string(typeDescription)
        }
        if let fileSize = values.fileSize {
            object["file_size_bytes"] = .number(Double(fileSize))
        }
        if let modified = values.contentModificationDate {
            object["modified_at"] = .string(ISO8601DateFormatter().string(from: modified))
        }
        if let created = values.creationDate {
            object["created_at"] = .string(ISO8601DateFormatter().string(from: created))
        }

        return try encode(object)
    }

    private func encode(_ object: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(object)
        return String(decoding: data, as: UTF8.self)
    }
}
