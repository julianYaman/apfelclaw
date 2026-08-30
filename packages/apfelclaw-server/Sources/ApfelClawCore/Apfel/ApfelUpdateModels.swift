import Foundation

public enum ApfelInstallSource: String, Codable, Sendable {
    case homebrew
    case manual
    case unknown
}

public enum ApfelRestartMode: String, Codable, Sendable {
    case appManaged = "app-managed"
    case homebrewService = "homebrew-service"
    case unavailable
}

public enum ApfelMaintenanceOperation: String, Codable, Sendable {
    case restart
    case upgrade
}

public struct ApfelMaintenanceState: Codable, Sendable {
    public let inProgress: Bool
    public let operation: String?
    public let message: String?

    public init(inProgress: Bool, operation: String? = nil, message: String? = nil) {
        self.inProgress = inProgress
        self.operation = operation
        self.message = message
    }

    public static let idle = ApfelMaintenanceState(inProgress: false)
}

public enum ApfelCompatibility {
    public static let recommendedMinimumVersion = "1.8.4"

    static func meetsRecommendedMinimum(_ version: String?) -> Bool? {
        guard let version else {
            return nil
        }
        return ApfelVersion.isNewer(recommendedMinimumVersion, than: version) == false
    }
}

public struct ApfelRuntimeHealth: Codable, Sendable, Equatable {
    public let reachable: Bool
    public let status: String?
    public let modelAvailable: Bool?
    public let prewarmed: Bool?
    public let contextWindow: Int?
    public let model: String?
    public let version: String?
    public let activeRequests: Int?
    public let isApfel: Bool
    public let host: String?
    public let port: Int?
    public let httpStatusCode: Int?

    public init(
        reachable: Bool,
        status: String? = nil,
        modelAvailable: Bool? = nil,
        prewarmed: Bool? = nil,
        contextWindow: Int? = nil,
        model: String? = nil,
        version: String? = nil,
        activeRequests: Int? = nil,
        isApfel: Bool = false,
        host: String? = nil,
        port: Int? = nil,
        httpStatusCode: Int? = nil
    ) {
        self.reachable = reachable
        self.status = status
        self.modelAvailable = modelAvailable
        self.prewarmed = prewarmed
        self.contextWindow = contextWindow
        self.model = model
        self.version = version
        self.activeRequests = activeRequests
        self.isApfel = isApfel
        self.host = host
        self.port = port
        self.httpStatusCode = httpStatusCode
    }

    public static let unreachable = ApfelRuntimeHealth(
        reachable: false
    )

    static func looksLikeApfel(model: String?, prewarmed: Bool?, contextWindow: Int?) -> Bool {
        if model == "apple-foundationmodel" {
            return true
        }
        if prewarmed != nil {
            return true
        }
        if let contextWindow, contextWindow > 0 {
            return true
        }
        return false
    }

    static func parse(data: Data, httpStatusCode: Int, endpoint: ApfelEndpoint? = nil) -> ApfelRuntimeHealth {
        guard (200 ..< 300).contains(httpStatusCode) else {
            return ApfelRuntimeHealth(
                reachable: false,
                isApfel: false,
                host: endpoint?.host,
                port: endpoint?.port,
                httpStatusCode: httpStatusCode
            )
        }

        guard let payload = try? JSONDecoder().decode(ApfelHealthPayload.self, from: data) else {
            return ApfelRuntimeHealth(
                reachable: true,
                isApfel: false,
                host: endpoint?.host,
                port: endpoint?.port,
                httpStatusCode: httpStatusCode
            )
        }

        let contextWindow = payload.contextWindow.flatMap { value in
            value > 0 ? value : nil
        }
        let isApfel = looksLikeApfel(
            model: payload.model,
            prewarmed: payload.prewarmed,
            contextWindow: contextWindow
        )

        return ApfelRuntimeHealth(
            reachable: true,
            status: payload.status,
            modelAvailable: payload.modelAvailable,
            prewarmed: payload.prewarmed,
            contextWindow: contextWindow,
            model: payload.model,
            version: payload.version,
            activeRequests: payload.activeRequests,
            isApfel: isApfel,
            host: endpoint?.host,
            port: endpoint?.port,
            httpStatusCode: httpStatusCode
        )
    }
}

private struct ApfelHealthPayload: Decodable {
    let status: String?
    let model: String?
    let version: String?
    let modelAvailable: Bool?
    let prewarmed: Bool?
    let contextWindow: Int?
    let activeRequests: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case model
        case version
        case modelAvailable = "model_available"
        case prewarmed
        case contextWindow = "context_window"
        case activeRequests = "active_requests"
    }
}

public struct ApfelStatusResponse: Codable, Sendable {
    public let executablePath: String?
    public let installedVersion: String?
    public let latestVersion: String?
    public let installSource: String
    public let updateAvailable: Bool
    public let canUpgrade: Bool
    public let canRestart: Bool
    public let restartMode: String
    public let upgradeCommand: String?
    public let releaseURL: String?
    public let lastCheckedAt: String?
    public let lastError: String?
    public let maintenance: ApfelMaintenanceState
    public let recommendedMinimumVersion: String
    public let meetsRecommendedMinimum: Bool?
    public let runtime: ApfelRuntimeHealth

    public init(
        executablePath: String?,
        installedVersion: String?,
        latestVersion: String?,
        installSource: String,
        updateAvailable: Bool,
        canUpgrade: Bool,
        canRestart: Bool,
        restartMode: String,
        upgradeCommand: String?,
        releaseURL: String?,
        lastCheckedAt: String?,
        lastError: String?,
        maintenance: ApfelMaintenanceState,
        recommendedMinimumVersion: String = ApfelCompatibility.recommendedMinimumVersion,
        meetsRecommendedMinimum: Bool?,
        runtime: ApfelRuntimeHealth
    ) {
        self.executablePath = executablePath
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.installSource = installSource
        self.updateAvailable = updateAvailable
        self.canUpgrade = canUpgrade
        self.canRestart = canRestart
        self.restartMode = restartMode
        self.upgradeCommand = upgradeCommand
        self.releaseURL = releaseURL
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
        self.maintenance = maintenance
        self.recommendedMinimumVersion = recommendedMinimumVersion
        self.meetsRecommendedMinimum = meetsRecommendedMinimum
        self.runtime = runtime
    }
}

public struct ApfelActionResponse: Codable, Sendable {
    public let message: String
    public let status: ApfelStatusResponse

    public init(message: String, status: ApfelStatusResponse) {
        self.message = message
        self.status = status
    }
}

struct ApfelEnvironmentSnapshot: Sendable {
    let executablePath: String?
    let installedVersion: String?
    let installSource: ApfelInstallSource
    let restartMode: ApfelRestartMode
    let brewPath: String?
}

struct ApfelRemoteRelease: Sendable {
    let version: String
    let releaseURL: String?
}

struct ApfelStatusSnapshot: Sendable {
    let environment: ApfelEnvironmentSnapshot
    let latestVersion: String?
    let updateAvailable: Bool
    let upgradeCommand: String?
    let releaseURL: String?
    let lastCheckedAt: String?
    let lastError: String?

    static let empty = ApfelStatusSnapshot(
        environment: ApfelEnvironmentSnapshot(
            executablePath: nil,
            installedVersion: nil,
            installSource: .unknown,
            restartMode: .unavailable,
            brewPath: nil
        ),
        latestVersion: nil,
        updateAvailable: false,
        upgradeCommand: nil,
        releaseURL: nil,
        lastCheckedAt: nil,
        lastError: nil
    )

    func response(
        maintenance: ApfelMaintenanceState,
        runtime: ApfelRuntimeHealth = .unreachable,
        lastError: String? = nil
    ) -> ApfelStatusResponse {
        ApfelStatusResponse(
            executablePath: environment.executablePath,
            installedVersion: environment.installedVersion,
            latestVersion: latestVersion,
            installSource: environment.installSource.rawValue,
            updateAvailable: updateAvailable,
            canUpgrade: environment.installSource == .homebrew && environment.brewPath != nil,
            canRestart: environment.restartMode != .unavailable,
            restartMode: environment.restartMode.rawValue,
            upgradeCommand: upgradeCommand,
            releaseURL: releaseURL,
            lastCheckedAt: lastCheckedAt,
            lastError: lastError ?? self.lastError,
            maintenance: maintenance,
            meetsRecommendedMinimum: ApfelCompatibility.meetsRecommendedMinimum(environment.installedVersion),
            runtime: runtime
        )
    }
}

enum ApfelVersion {
    static func normalized(_ raw: String) -> String? {
        let pattern = #"(\d+(?:\.\d+)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let valueRange = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }

        return String(raw[valueRange])
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left < right {
                return .orderedAscending
            }
            if left > right {
                return .orderedDescending
            }
        }

        return .orderedSame
    }
}
