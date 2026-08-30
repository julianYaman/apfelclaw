import Foundation

public struct ApfelEndpoint: Sendable, Equatable {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 11_434

    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var displayName: String {
        "\(host):\(port)"
    }

    public var originURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public var completionsURL: URL {
        originURL.appendingPathComponent("v1/chat/completions")
    }

    public var healthURL: URL {
        originURL.appendingPathComponent("health")
    }

    public static func resolve(
        config: AppConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ApfelEndpoint {
        let host = firstNonEmpty(
            environment["APFELCLAW_APFEL_HOST"],
            config.apfelHost,
            environment["APFEL_HOST"]
        ) ?? defaultHost

        let port = parsePort(environment["APFELCLAW_APFEL_PORT"])
            ?? config.apfelPort
            ?? parsePort(environment["APFEL_PORT"])
            ?? defaultPort

        return ApfelEndpoint(host: host, port: port)
    }

    public static func parsePort(_ raw: String?) -> Int? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false,
              let value = Int(trimmed),
              (1 ... 65_535).contains(value)
        else {
            return nil
        }
        return value
    }

    public static func validatePort(_ value: Int) throws -> Int {
        guard (1 ... 65_535).contains(value) else {
            throw AppError.message("'apfelPort' must be between 1 and 65535.")
        }
        return value
    }

    public static func validateHost(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw AppError.message("'apfelHost' cannot be empty.")
        }
        return trimmed
    }

    static func occupiedPortMessage(endpoint: ApfelEndpoint) -> String {
        var lines = [
            "Port \(endpoint.port) on \(endpoint.host) is already in use by another service, not apfel.",
        ]
        if endpoint.port == defaultPort {
            lines.append("Port \(defaultPort) is also the default for Ollama.")
        }
        lines.append(
            "Point apfelclaw at your apfel server by setting \"apfelPort\" in ~/.apfelclaw/config.json (for example 11436), then restart apfelclaw."
        )
        return lines.joined(separator: " ")
    }

    static func missingServerMessage(endpoint: ApfelEndpoint, logPath: String? = nil) -> String {
        var message = "apfel did not become healthy at \(endpoint.displayName)."
        if let logPath, logPath.isEmpty == false {
            message += " See \(logPath) for apfel output."
        }
        message += " If another app owns that port, set \"apfelPort\" in ~/.apfelclaw/config.json and restart apfelclaw."
        return message
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, trimmed.isEmpty == false {
                return trimmed
            }
        }
        return nil
    }
}
