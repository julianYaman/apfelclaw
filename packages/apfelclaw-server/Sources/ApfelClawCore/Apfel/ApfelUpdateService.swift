import Foundation

public actor ApfelUpdateService {
    private let apfelManager: ApfelManager
    private let refreshInterval: Duration
    private let now: @Sendable () -> Date
    private let fetchData: @Sendable (URL) async throws -> Data
    private let runCommand: @Sendable (String, [String], TimeInterval) throws -> CommandResult
    private let resolveExecutable: @Sendable (String) -> String?
    private let inspectEnvironmentOverride: (@Sendable () throws -> ApfelEnvironmentSnapshot)?
    private var task: Task<Void, Never>?
    private var snapshot = ApfelStatusSnapshot.empty
    private let isoFormatter = ISO8601DateFormatter()

    public init(
        apfelManager: ApfelManager,
        refreshInterval: Duration = .seconds(86_400),
        now: @escaping @Sendable () -> Date = Date.init,
        fetchData: (@Sendable (URL) async throws -> Data)? = nil,
        runCommand: (@Sendable (String, [String], TimeInterval) throws -> CommandResult)? = nil,
        resolveExecutable: (@Sendable (String) -> String?)? = nil
    ) {
        self.apfelManager = apfelManager
        self.refreshInterval = refreshInterval
        self.now = now
        self.fetchData = fetchData ?? { url in
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        self.runCommand = runCommand ?? { executable, arguments, timeout in
            try CommandRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        }
        self.resolveExecutable = resolveExecutable ?? { executable in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [executable]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    return nil
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            } catch {
                return nil
            }
        }
        self.inspectEnvironmentOverride = nil
    }

    init(
        apfelManager: ApfelManager,
        refreshInterval: Duration = .seconds(86_400),
        now: @escaping @Sendable () -> Date = Date.init,
        fetchData: @escaping @Sendable (URL) async throws -> Data,
        runCommand: @escaping @Sendable (String, [String], TimeInterval) throws -> CommandResult,
        resolveExecutable: @escaping @Sendable (String) -> String?,
        inspectEnvironment: @escaping @Sendable () throws -> ApfelEnvironmentSnapshot
    ) {
        self.apfelManager = apfelManager
        self.refreshInterval = refreshInterval
        self.now = now
        self.fetchData = fetchData
        self.runCommand = runCommand
        self.resolveExecutable = resolveExecutable
        self.inspectEnvironmentOverride = inspectEnvironment
    }

    public func start() async {
        guard task == nil else {
            return
        }

        await refreshNow()

        task = Task {
            await runLoop()
        }
    }

    public func shutdown() {
        task?.cancel()
        task = nil
    }

    @discardableResult
    func refreshNow() async -> ApfelStatusSnapshot {
        do {
            let environment = try inspectEnvironment()
            let latestRelease = try await fetchLatestRelease(for: environment.installSource)
            let updateAvailable = latestRelease.map { release in
                guard let installedVersion = environment.installedVersion else {
                    return false
                }
                return ApfelVersion.isNewer(release.version, than: installedVersion)
            } ?? false

            let next = ApfelStatusSnapshot(
                environment: environment,
                latestVersion: latestRelease?.version,
                updateAvailable: updateAvailable,
                upgradeCommand: environment.installSource == .homebrew ? "brew upgrade apfel" : nil,
                releaseURL: latestRelease?.releaseURL,
                lastCheckedAt: isoFormatter.string(from: now()),
                lastError: nil
            )
            snapshot = next
            return next
        } catch {
            let next = ApfelStatusSnapshot(
                environment: snapshot.environment,
                latestVersion: snapshot.latestVersion,
                updateAvailable: snapshot.updateAvailable,
                upgradeCommand: snapshot.upgradeCommand,
                releaseURL: snapshot.releaseURL,
                lastCheckedAt: isoFormatter.string(from: now()),
                lastError: error.localizedDescription
            )
            snapshot = next
            return next
        }
    }

    public func currentResponse(maintenance: ApfelMaintenanceState) -> ApfelStatusResponse {
        snapshot.response(maintenance: maintenance)
    }

    func currentSnapshot() -> ApfelStatusSnapshot {
        snapshot
    }

    private func runLoop() async {
        while Task.isCancelled == false {
            do {
                try await Task.sleep(for: refreshInterval)
            } catch {
                return
            }

            if Task.isCancelled {
                return
            }
            await refreshNow()
        }
    }

    private func inspectEnvironment() throws -> ApfelEnvironmentSnapshot {
        if let inspectEnvironmentOverride {
            return try inspectEnvironmentOverride()
        }

        let executablePath = try? apfelManager.resolveApfelPath()
        let installedVersion = try apfelManager.installedVersion()
        guard let normalizedInstalledVersion = ApfelVersion.normalized(installedVersion) else {
            throw AppError.message("Unable to parse apfel version from '\(installedVersion)'.")
        }

        let brewPath = resolveExecutable("brew")
        let brewInstall = try brewPath.map { try loadBrewInstallInfo(from: $0) }

        var installSource: ApfelInstallSource = .manual
        var restartMode: ApfelRestartMode = apfelManager.ownsManagedProcess() ? .appManaged : .unavailable

        if brewInstall?.isInstalled == true {
            installSource = .homebrew
            if restartMode == .unavailable,
               brewInstall?.serviceRegistered == true || brewInstall?.serviceRunning == true {
                restartMode = .homebrewService
            }
        }

        return ApfelEnvironmentSnapshot(
            executablePath: executablePath,
            installedVersion: normalizedInstalledVersion,
            installSource: installSource,
            restartMode: restartMode,
            brewPath: brewPath
        )
    }

    private func fetchLatestRelease(for installSource: ApfelInstallSource) async throws -> ApfelRemoteRelease? {
        switch installSource {
        case .homebrew:
            let data = try await fetchData(URL(string: "https://formulae.brew.sh/api/formula/apfel.json")!)
            let response = try JSONDecoder().decode(HomebrewFormulaResponse.self, from: data)
            return ApfelRemoteRelease(version: response.versions.stable, releaseURL: nil)
        case .manual:
            let data = try await fetchData(URL(string: "https://api.github.com/repos/Arthur-Ficial/apfel/releases/latest")!)
            let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
            guard let version = ApfelVersion.normalized(response.tagName) else {
                throw AppError.message("Unable to parse the latest apfel release version.")
            }
            return ApfelRemoteRelease(version: version, releaseURL: response.htmlURL)
        case .unknown:
            return nil
        }
    }

    private func loadBrewInstallInfo(from brewPath: String) throws -> BrewInstallInfo {
        let infoResult = try runCommand(brewPath, ["info", "--json=v2", "apfel"], 10)
        guard infoResult.exitCode == 0 else {
            let stderr = infoResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(stderr.isEmpty ? "Unable to inspect apfel Homebrew metadata." : stderr)
        }

        let info = try JSONDecoder().decode(BrewInfoResponse.self, from: Data(infoResult.stdout.utf8))
        let formula = info.formulae.first

        var serviceRegistered = false
        var serviceRunning = false
        if let servicesResult = try? runCommand(brewPath, ["services", "info", "apfel", "--json"], 10),
           servicesResult.exitCode == 0,
           let serviceInfo = try? JSONDecoder().decode([BrewServiceInfo].self, from: Data(servicesResult.stdout.utf8)),
           let firstService = serviceInfo.first {
            serviceRegistered = firstService.registered ?? false
            serviceRunning = firstService.running ?? false
        }

        return BrewInstallInfo(
            isInstalled: formula?.installed.isEmpty == false,
            serviceRegistered: serviceRegistered,
            serviceRunning: serviceRunning
        )
    }
}

private struct BrewInstallInfo: Sendable {
    let isInstalled: Bool
    let serviceRegistered: Bool
    let serviceRunning: Bool
}

private struct BrewInfoResponse: Decodable {
    let formulae: [BrewFormula]
}

private struct BrewFormula: Decodable {
    let installed: [BrewInstalledVersion]
}

private struct BrewInstalledVersion: Decodable {}

private struct BrewServiceInfo: Decodable {
    let running: Bool?
    let registered: Bool?
}

private struct HomebrewFormulaResponse: Decodable {
    struct Versions: Decodable {
        let stable: String
    }

    let versions: Versions
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
