import Foundation

public struct ToolManifest: Codable, Sendable {
    public let tools: [ToolManifestEntry]
}

public struct ToolManifestEntry: Codable, Sendable {
    public let name: String
    public let description: String
    public let readonly: Bool
    public let requiresConfirmation: Bool
    public let resultFormat: String
    public let useWhen: String?
    public let avoidWhen: String?
    public let examples: [String]?
    public let returns: String?
    public let parameters: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case readonly
        case requiresConfirmation = "requires_confirmation"
        case resultFormat = "result_format"
        case useWhen = "use_when"
        case avoidWhen = "avoid_when"
        case examples
        case returns
        case parameters
    }
}

public enum ToolCatalogLoader {
    public static func loadManifest() throws -> ToolManifest {
        guard let url = Bundle.module.url(forResource: "tools", withExtension: "json") else {
            throw AppError.message("Unable to locate tools.json in bundled resources.")
        }

        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ToolManifest.self, from: data)

        guard manifest.tools.isEmpty == false else {
            throw AppError.message("tools.json does not define any tools.")
        }

        return manifest
    }
}
