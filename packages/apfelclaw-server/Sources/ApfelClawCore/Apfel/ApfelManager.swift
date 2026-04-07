import Foundation

public struct ApfelStatus: Sendable {
    public let executablePath: String
    public let isRunning: Bool
    public let wasStartedByApp: Bool
}

public final class ApfelManager: @unchecked Sendable {
    private let config: AppConfig
    private var process: Process?
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    public init(config: AppConfig) {
        self.config = config
    }

    public func ensureServerRunning() async throws -> ApfelStatus {
        let executable = try resolveApfelPath()

        if await isHealthy() {
            return ApfelStatus(executablePath: executable, isRunning: true, wasStartedByApp: false)
        }

        guard config.apfelAutostartEnabled else {
            throw AppError.message("apfel is installed but not running, and autostart is disabled.")
        }

        try startServer(executablePath: executable)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await isHealthy() {
                return ApfelStatus(executablePath: executable, isRunning: true, wasStartedByApp: true)
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        throw AppError.message("apfel did not become healthy after startup.")
    }

    public func shutdownIfOwned() {
        guard let process else {
            return
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    public func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return (200 ..< 300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func resolveApfelPath() throws -> String {
        if let path = shellWhich("apfel") {
            return path
        }

        throw AppError.message("`apfel` was not found in PATH. Install it before starting apfelclaw-server.")
    }

    private func startServer(executablePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--serve", "--host", "127.0.0.1", "--port", "11434"]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apfelclaw-apfel.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
        self.process = process
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
