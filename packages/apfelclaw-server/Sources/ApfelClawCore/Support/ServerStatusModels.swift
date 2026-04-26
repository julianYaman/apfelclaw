import Foundation

public struct ServerStatusResponse: Codable, Sendable {
    public let version: String
    public let startedAt: String
    public let uptimeSeconds: Int
    public let onboardingCompleted: Bool
    public let sessionCount: Int
    public let apfel: ApfelStatusResponse
    public let remoteControl: RemoteControlStatus

    public init(
        version: String,
        startedAt: String,
        uptimeSeconds: Int,
        onboardingCompleted: Bool,
        sessionCount: Int,
        apfel: ApfelStatusResponse,
        remoteControl: RemoteControlStatus
    ) {
        self.version = version
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.onboardingCompleted = onboardingCompleted
        self.sessionCount = sessionCount
        self.apfel = apfel
        self.remoteControl = remoteControl
    }
}

public struct LocalStatusSummary: Sendable {
    public let installState: InstallState
    public let backendRunning: Bool
    public let liveStatus: ServerStatusResponse?
    public let storedRemoteControl: RemoteControlStatus
    public let storedConfig: EditableAppConfig?

    public init(
        installState: InstallState,
        backendRunning: Bool,
        liveStatus: ServerStatusResponse?,
        storedRemoteControl: RemoteControlStatus,
        storedConfig: EditableAppConfig?
    ) {
        self.installState = installState
        self.backendRunning = backendRunning
        self.liveStatus = liveStatus
        self.storedRemoteControl = storedRemoteControl
        self.storedConfig = storedConfig
    }
}
