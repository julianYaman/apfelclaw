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
        maintenance: ApfelMaintenanceState
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

    func response(maintenance: ApfelMaintenanceState) -> ApfelStatusResponse {
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
            lastError: lastError,
            maintenance: maintenance
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
