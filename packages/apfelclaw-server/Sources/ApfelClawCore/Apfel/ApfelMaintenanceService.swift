import Foundation

public actor ApfelMaintenanceService {
    private let apfelManager: ApfelManager
    private let updateService: ApfelUpdateService
    private let runCommand: @Sendable (String, [String], TimeInterval) throws -> CommandResult
    private var state = ApfelMaintenanceState.idle

    public init(
        apfelManager: ApfelManager,
        updateService: ApfelUpdateService,
        runCommand: (@Sendable (String, [String], TimeInterval) throws -> CommandResult)? = nil
    ) {
        self.apfelManager = apfelManager
        self.updateService = updateService
        self.runCommand = runCommand ?? { executable, arguments, timeout in
            try CommandRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        }
    }

    public func currentState() -> ApfelMaintenanceState {
        state
    }

    public func ensureAvailable() throws {
        guard state.inProgress == false else {
            throw AppError.message(state.message ?? "apfel maintenance is in progress. Try again in a moment.")
        }
    }

    public func restart() async throws -> ApfelActionResponse {
        try begin(.restart, message: "Restarting apfel…")
        do {
            let snapshot = await updateService.refreshNow()
            let message: String

            switch snapshot.environment.restartMode {
            case .appManaged:
                _ = try await apfelManager.restartOwnedServer()
                message = "Restarted apfel managed by apfelclaw."
            case .homebrewService:
                guard let brewPath = snapshot.environment.brewPath else {
                    throw AppError.message("Homebrew is required to restart the apfel service.")
                }
                try runOrThrow(executable: brewPath, arguments: ["services", "restart", "apfel"], timeout: 120)
                try await waitUntilHealthy()
                message = "Restarted the Homebrew apfel service."
            case .unavailable:
                throw AppError.message("apfel is not managed by apfelclaw or a registered Homebrew service, so restart is unavailable.")
            }

            state = .idle
            let refreshed = await updateService.refreshNow()
            return ApfelActionResponse(message: message, status: refreshed.response(maintenance: state))
        } catch {
            state = .idle
            throw error
        }
    }

    public func upgrade() async throws -> ApfelActionResponse {
        try begin(.upgrade, message: "Upgrading apfel…")
        do {
            let snapshot = await updateService.refreshNow()
            guard snapshot.environment.installSource == .homebrew,
                  let brewPath = snapshot.environment.brewPath
            else {
                throw AppError.message("Automatic upgrade is only supported when apfel is installed with Homebrew.")
            }

            try runOrThrow(executable: brewPath, arguments: ["upgrade", "apfel"], timeout: 600)

            var message = "Upgraded apfel via Homebrew."
            switch snapshot.environment.restartMode {
            case .appManaged:
                state = ApfelMaintenanceState(inProgress: true, operation: ApfelMaintenanceOperation.upgrade.rawValue, message: "Upgraded apfel. Restarting apfel…")
                _ = try await apfelManager.restartOwnedServer()
                message += " Restarted apfel."
            case .homebrewService:
                state = ApfelMaintenanceState(inProgress: true, operation: ApfelMaintenanceOperation.upgrade.rawValue, message: "Upgraded apfel. Restarting Homebrew service…")
                try runOrThrow(executable: brewPath, arguments: ["services", "restart", "apfel"], timeout: 120)
                try await waitUntilHealthy()
                message += " Restarted the Homebrew apfel service."
            case .unavailable:
                message += " Restart apfel manually to load the new version."
            }

            state = .idle
            let refreshed = await updateService.refreshNow()
            let resolvedMessage: String
            if let installedVersion = refreshed.environment.installedVersion {
                resolvedMessage = "\(message) Current version: \(installedVersion)."
            } else {
                resolvedMessage = message
            }
            return ApfelActionResponse(message: resolvedMessage, status: refreshed.response(maintenance: state))
        } catch {
            state = .idle
            throw error
        }
    }

    private func begin(_ operation: ApfelMaintenanceOperation, message: String) throws {
        guard state.inProgress == false else {
            throw AppError.message(state.message ?? "apfel maintenance is already in progress.")
        }
        state = ApfelMaintenanceState(inProgress: true, operation: operation.rawValue, message: message)
    }

    private func runOrThrow(executable: String, arguments: [String], timeout: TimeInterval) throws {
        let result = try runCommand(executable, arguments, timeout)
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(stderr.isEmpty ? "Command failed: \(arguments.joined(separator: " "))" : stderr)
        }
    }

    private func waitUntilHealthy() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if await apfelManager.isHealthy() {
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        throw AppError.message("apfel did not become healthy after restart.")
    }
}
