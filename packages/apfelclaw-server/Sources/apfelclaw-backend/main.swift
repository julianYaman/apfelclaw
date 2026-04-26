import ApfelClawServerRuntime
import Foundation

@main
struct ApfelClawBackendMain {
    static func main() async throws {
        let pidFileURL = ProcessInfo.processInfo.environment["APFELCLAW_PID_FILE"].flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value)
        }
        try await ApfelClawServerRuntime.run(pidFileURL: pidFileURL)
    }
}
