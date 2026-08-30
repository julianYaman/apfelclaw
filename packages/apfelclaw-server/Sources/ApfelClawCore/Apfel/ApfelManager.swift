import Foundation

public struct ApfelStatus: Sendable {
    public let executablePath: String
    public let isRunning: Bool
    public let wasStartedByApp: Bool
}

public final class ApfelManager: @unchecked Sendable {
    private let config: AppConfig
    private var process: Process?
    private let lock = NSLock()
    private let startupTimeout: TimeInterval = 45
    private var lastConnectError: String?

    public let endpoint: ApfelEndpoint

    public init(config: AppConfig, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.config = config
        self.endpoint = ApfelEndpoint.resolve(config: config, environment: environment)
    }

    public func ensureServerRunning() async throws -> ApfelStatus {
        let executable = try resolveApfelPath()

        switch await probe() {
        case .apfel:
            setLastConnectError(nil)
            return ApfelStatus(executablePath: executable, isRunning: true, wasStartedByApp: false)
        case .occupied:
            let message = ApfelEndpoint.occupiedPortMessage(endpoint: endpoint)
            setLastConnectError(message)
            throw AppError.message(message)
        case .empty:
            break
        }

        guard config.apfelAutostartEnabled else {
            let message = "apfel is not reachable at \(endpoint.displayName), and autostart is disabled."
            setLastConnectError(message)
            throw AppError.message(message)
        }

        try startServer(executablePath: executable)

        if let earlyFailure = processFailureMessage() {
            setLastConnectError(earlyFailure)
            throw AppError.message(earlyFailure)
        }

        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if let earlyFailure = processFailureMessage() {
                setLastConnectError(earlyFailure)
                throw AppError.message(earlyFailure)
            }
            if await isHealthy() {
                setLastConnectError(nil)
                return ApfelStatus(executablePath: executable, isRunning: true, wasStartedByApp: true)
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        let message = ApfelEndpoint.missingServerMessage(endpoint: endpoint, logPath: apfelLogURL.path)
        setLastConnectError(message)
        throw AppError.message(message)
    }

    public func ensureReadyForRequests() async throws {
        if await isHealthy() {
            return
        }
        if let lastConnectError = connectError() {
            throw AppError.message(lastConnectError)
        }
        _ = try await ensureServerRunning()
    }

    public func shutdownIfOwned() {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()

        guard let process else {
            return
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    public func ownsManagedProcess() -> Bool {
        lock.lock()
        let isRunning = process?.isRunning == true
        lock.unlock()
        return isRunning
    }

    public func isHealthy() async -> Bool {
        await runtimeHealth().isApfel
    }

    public func runtimeHealth() async -> ApfelRuntimeHealth {
        await probeHealth()
    }

    public func connectError() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastConnectError
    }

    private func setLastConnectError(_ message: String?) {
        lock.lock()
        lastConnectError = message
        lock.unlock()
    }

    public func resolveApfelPath() throws -> String {
        if let path = shellWhich("apfel") {
            return path
        }

        let fallbackCandidates = [
            "/opt/homebrew/bin/apfel",
            "/usr/local/bin/apfel",
        ]

        for candidate in fallbackCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw AppError.message("`apfel` was not found in PATH. Install it before starting apfelclaw.")
    }

    public func installedVersion() throws -> String {
        let executable = try resolveApfelPath()
        let result = try CommandRunner.run(executable: executable, arguments: ["--version"], timeout: 5)
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(stderr.isEmpty ? "Unable to read apfel version." : stderr)
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.isEmpty == false else {
            throw AppError.message("Unable to read apfel version.")
        }
        return output
    }

    public func restartOwnedServer() async throws -> ApfelStatus {
        guard ownsManagedProcess() else {
            throw AppError.message("apfel is not managed by apfelclaw, so it cannot be restarted automatically.")
        }

        let executable = try resolveApfelPath()
        shutdownIfOwned()
        try startServer(executablePath: executable)

        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if let earlyFailure = processFailureMessage() {
                setLastConnectError(earlyFailure)
                throw AppError.message(earlyFailure)
            }
            if await isHealthy() {
                setLastConnectError(nil)
                return ApfelStatus(executablePath: executable, isRunning: true, wasStartedByApp: true)
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        let message = ApfelEndpoint.missingServerMessage(endpoint: endpoint, logPath: apfelLogURL.path)
        setLastConnectError(message)
        throw AppError.message(message)
    }

    enum PortProbe: Sendable {
        case empty
        case apfel
        case occupied
    }

    func probe() async -> PortProbe {
        let health = await probeHealth()
        if health.isApfel {
            return .apfel
        }
        if health.httpStatusCode != nil {
            return .occupied
        }
        return .empty
    }

    private func probeHealth() async -> ApfelRuntimeHealth {
        var request = URLRequest(url: endpoint.healthURL)
        request.timeoutInterval = 3.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ApfelRuntimeHealth(reachable: false, host: endpoint.host, port: endpoint.port)
            }
            return ApfelRuntimeHealth.parse(data: data, httpStatusCode: http.statusCode, endpoint: endpoint)
        } catch {
            return ApfelRuntimeHealth(reachable: false, host: endpoint.host, port: endpoint.port)
        }
    }

    private func startServer(executablePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--permissive",
            "--serve",
            "--host",
            endpoint.host,
            "--port",
            String(endpoint.port),
        ]

        FileManager.default.createFile(atPath: apfelLogURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: apfelLogURL)
        try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
        lock.lock()
        self.process = process
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.2)
    }

    private var apfelLogURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("apfelclaw-apfel.log")
    }

    private func processFailureMessage() -> String? {
        lock.lock()
        let process = self.process
        lock.unlock()

        guard let process, process.isRunning == false else {
            return nil
        }

        let logTail = (try? String(contentsOf: apfelLogURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let logTail, logTail.localizedCaseInsensitiveContains("already in use") {
            return ApfelEndpoint.occupiedPortMessage(endpoint: endpoint)
        }
        if let logTail, logTail.isEmpty == false {
            let snippet = logTail.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " ")
            return ApfelEndpoint.missingServerMessage(endpoint: endpoint, logPath: apfelLogURL.path) + " apfel output: \(snippet)"
        }
        return ApfelEndpoint.missingServerMessage(endpoint: endpoint, logPath: apfelLogURL.path)
    }

    private func shellWhich(_ executable: String) -> String? {
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
}
