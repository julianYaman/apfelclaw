import Foundation
import Testing
@testable import ApfelClawCore

@Test
func safeCommandsArePresent() {
    #expect(SafeCommandRegistry.commands.contains { $0.name == "mdfind" })
}

@Test
func apfelVersionNormalizesCommonFormats() {
    #expect(ApfelVersion.normalized("apfel v1.3.0") == "1.3.0")
    #expect(ApfelVersion.normalized("v1.4.2") == "1.4.2")
    #expect(ApfelVersion.normalized("release 2.0.1 build") == "2.0.1")
}

@Test
func apfelVersionComparisonDetectsNewerReleases() {
    #expect(ApfelVersion.isNewer("1.4.0", than: "1.3.9") == true)
    #expect(ApfelVersion.isNewer("1.4.0", than: "1.4.0") == false)
    #expect(ApfelVersion.isNewer("1.4.0", than: "1.4") == false)
}

@Test
func apfelUpdateServiceUsesHomebrewLatestVersionForHomebrewInstalls() async {
    let apfelManager = ApfelManager(config: .default)
    let service = ApfelUpdateService(
        apfelManager: apfelManager,
        now: { ISO8601DateFormatter().date(from: "2026-04-26T01:00:00Z")! },
        fetchData: { url in
            #expect(url.absoluteString == "https://formulae.brew.sh/api/formula/apfel.json")
            return Data(#"{"versions":{"stable":"1.4.0"}}"#.utf8)
        },
        runCommand: { _, _, _ in CommandResult(stdout: "", stderr: "", exitCode: 0) },
        resolveExecutable: { _ in nil },
        inspectEnvironment: {
            ApfelEnvironmentSnapshot(
                executablePath: "/opt/homebrew/bin/apfel",
                installedVersion: "1.3.0",
                installSource: .homebrew,
                restartMode: .homebrewService,
                brewPath: "/opt/homebrew/bin/brew"
            )
        }
    )

    _ = await service.refreshNow()
    let response = await service.currentResponse(maintenance: .idle)

    #expect(response.latestVersion == "1.4.0")
    #expect(response.updateAvailable == true)
    #expect(response.canUpgrade == true)
    #expect(response.canRestart == true)
    #expect(response.restartMode == ApfelRestartMode.homebrewService.rawValue)
}

@Test
func apfelMaintenanceServiceUpgradesHomebrewInstallAndRefreshesStatus() async throws {
    let apfelManager = ApfelManager(config: .default)
    let versionBox = VersionBox(version: "1.3.0")
    let commandBox = CommandBox()
    let service = ApfelUpdateService(
        apfelManager: apfelManager,
        now: { ISO8601DateFormatter().date(from: "2026-04-26T01:05:00Z")! },
        fetchData: { _ in
            Data(#"{"versions":{"stable":"1.4.0"}}"#.utf8)
        },
        runCommand: { _, _, _ in CommandResult(stdout: "", stderr: "", exitCode: 0) },
        resolveExecutable: { _ in nil },
        inspectEnvironment: {
            ApfelEnvironmentSnapshot(
                executablePath: "/opt/homebrew/bin/apfel",
                installedVersion: versionBox.version,
                installSource: .homebrew,
                restartMode: .unavailable,
                brewPath: "/opt/homebrew/bin/brew"
            )
        }
    )
    let maintenance = ApfelMaintenanceService(
        apfelManager: apfelManager,
        updateService: service,
        runCommand: { executable, arguments, _ in
            #expect(executable == "/opt/homebrew/bin/brew")
            commandBox.commands.append(arguments)
            if arguments == ["upgrade", "apfel"] {
                versionBox.version = "1.4.0"
            }
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
    )

    let result = try await maintenance.upgrade()

    #expect(commandBox.commands == [["upgrade", "apfel"]])
    #expect(result.message.contains("Upgraded apfel via Homebrew.") == true)
    #expect(result.message.contains("Restart apfel manually") == true)
    #expect(result.status.installedVersion == "1.4.0")
    #expect(result.status.updateAvailable == false)
}

private final class VersionBox: @unchecked Sendable {
    var version: String

    init(version: String) {
        self.version = version
    }
}

private final class CommandBox: @unchecked Sendable {
    var commands: [[String]] = []
}
