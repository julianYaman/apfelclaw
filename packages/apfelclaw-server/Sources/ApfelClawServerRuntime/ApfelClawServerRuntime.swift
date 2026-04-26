import ApfelClawCore
import Dispatch
import Foundation
import Vapor

extension SessionRecord: Content {}
extension SessionMessage: Content {}
extension ToolExecutionSummary: Content {}
extension ConversationTurnResponse: Content {}
extension StreamEvent: Content {}
extension EditableAppConfig: Content {}
extension EditableAppConfigUpdate: Content {}
extension RemoteControlStatus: Content {}
extension TelegramRemoteControlStatus: Content {}
extension TelegramRemoteControlSetupRequest: Content {}
extension ApfelMaintenanceState: Content {}
extension ApfelStatusResponse: Content {}
extension ApfelActionResponse: Content {}
extension ServerStatusResponse: Content {}

private struct CreateSessionRequest: Content {
    let title: String?
}

private struct SendMessageRequest: Content {
    let content: String
    let autoApproveTools: Bool?
}

private struct SessionMessagesResponse: Content {
    let sessionID: Int64
    let messages: [SessionMessage]
}

public enum ApfelClawServerRuntime {
    public static func run(pidFileURL: URL? = nil) async throws {
        let startedAt = Date()
        let startedAtString = ISO8601DateFormatter().string(from: startedAt)
        let bootstrap = try await ServerBootstrap.make()
        let app = try await Application.make(.development)
        let signalHandler = GracefulShutdownHandler(application: app)
        let pidFile = try PIDFileScope(url: pidFileURL)

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 4242
        app.middleware.use(ServerVersionMiddleware())
        app.middleware.use(DebugRequestLoggingMiddleware(configService: bootstrap.configService))

        try routes(app: app, bootstrap: bootstrap, startedAt: startedAt, startedAtString: startedAtString)
        signalHandler.install()
        do {
            try await app.execute()
            signalHandler.cancel()
            try pidFile.cleanup()
            bootstrap.telegramRemoteControlProvider.shutdown()
            await bootstrap.apfelUpdateService.shutdown()
            bootstrap.apfelManager.shutdownIfOwned()
            try? await app.asyncShutdown()
        } catch {
            signalHandler.cancel()
            try? pidFile.cleanup()
            bootstrap.telegramRemoteControlProvider.shutdown()
            await bootstrap.apfelUpdateService.shutdown()
            bootstrap.apfelManager.shutdownIfOwned()
            try? await app.asyncShutdown()
            throw error
        }
    }

    private static func routes(
        app: Application,
        bootstrap: ServerBootstrap,
        startedAt: Date,
        startedAtString: String
    ) throws {
        app.get("health") { _ in
            ["status": "ok"]
        }

        app.get("status") { _ async in
            let maintenance = await bootstrap.apfelMaintenanceService.currentState()
            let apfelStatus = await bootstrap.apfelUpdateService.currentResponse(maintenance: maintenance)
            let state = (try? bootstrap.installStateStore.current(defaultInstallSource: AppInstallSourceDetector.detectCurrentInstallSource()))
                ?? InstallState(installSource: AppInstallSourceDetector.detectCurrentInstallSource())
            let uptime = max(0, Int(Date().timeIntervalSince(startedAt)))
            let sessionCount = (try? bootstrap.memoryStore.sessionCount()) ?? 0
            let remoteControl = await bootstrap.remoteControlService.current()

            return ServerStatusResponse(
                version: AppVersion.current,
                startedAt: startedAtString,
                uptimeSeconds: uptime,
                onboardingCompleted: state.onboardingCompleted,
                sessionCount: sessionCount,
                apfel: apfelStatus,
                remoteControl: remoteControl
            )
        }

        app.get("config") { _ async in
            await bootstrap.configService.current()
        }

        app.patch("config") { req async throws in
            let update = try req.content.decode(EditableAppConfigUpdate.self)
            do {
                return try await bootstrap.configService.update(update)
            } catch let error as AppError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
        }

        app.get("tools") { _ in
            bootstrap.toolRuntime.availableTools.map { tool in
                [
                    "name": tool.name,
                    "summary": tool.summary,
                    "description": tool.description,
                ]
            }
        }

        app.get("remotecontrol") { _ async in
            await bootstrap.remoteControlService.current()
        }

        app.get("remotecontrol", "providers", "telegram") { _ async in
            await bootstrap.remoteControlService.telegramStatus()
        }

        app.get("apfel", "status") { _ async in
            let maintenance = await bootstrap.apfelMaintenanceService.currentState()
            return await bootstrap.apfelUpdateService.currentResponse(maintenance: maintenance)
        }

        app.post("apfel", "restart") { _ async throws in
            do {
                return try await bootstrap.apfelMaintenanceService.restart()
            } catch let error as AppError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
        }

        app.post("apfel", "upgrade") { _ async throws in
            do {
                return try await bootstrap.apfelMaintenanceService.upgrade()
            } catch let error as AppError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
        }

        app.post("remotecontrol", "providers", "telegram", "setup") { req async throws in
            let body = try req.content.decode(TelegramRemoteControlSetupRequest.self)
            do {
                return try await bootstrap.remoteControlService.setupTelegram(botToken: body.botToken)
            } catch let error as AppError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
        }

        app.post("remotecontrol", "providers", "telegram", "disable") { _ async throws in
            do {
                return try await bootstrap.remoteControlService.disableTelegram()
            } catch let error as AppError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
        }

        app.post("remotecontrol", "providers", "telegram", "reset") { _ async throws in
            do {
                let status = try await bootstrap.remoteControlService.resetTelegram()
                try bootstrap.memoryStore.deleteRemoteSessions(provider: "telegram")
                return status
            } catch let error as AppError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
        }

        app.get("sessions") { _ in
            try bootstrap.conversationService.listSessions()
        }

        app.post("sessions") { req in
            let body = try? req.content.decode(CreateSessionRequest.self)
            return try bootstrap.conversationService.createSession(title: body?.title)
        }

        app.get("sessions", ":sessionID", "messages") { req in
            guard let raw = req.parameters.get("sessionID"), let sessionID = Int64(raw) else {
                throw Abort(.badRequest, reason: "Invalid session id.")
            }

            return try SessionMessagesResponse(
                sessionID: sessionID,
                messages: bootstrap.conversationService.listMessages(sessionID: sessionID)
            )
        }

        app.post("sessions", ":sessionID", "messages") { req async throws in
            guard let raw = req.parameters.get("sessionID"), let sessionID = Int64(raw) else {
                throw Abort(.badRequest, reason: "Invalid session id.")
            }

            let body = try req.content.decode(SendMessageRequest.self)
            return try await bootstrap.conversationService.sendMessage(
                sessionID: sessionID,
                userInput: body.content,
                autoApproveTools: body.autoApproveTools ?? false
            )
        }

        app.webSocket("sessions", ":sessionID", "stream") { req, ws in
            guard let raw = req.parameters.get("sessionID"), let sessionID = Int64(raw) else {
                ws.close(promise: nil)
                return
            }

            let subscriptionID = bootstrap.eventHub.subscribe(sessionID: sessionID) { payload in
                ws.eventLoop.execute {
                    ws.send(payload)
                }
            }

            ws.onClose.whenComplete { _ in
                bootstrap.eventHub.unsubscribe(sessionID: sessionID, id: subscriptionID)
            }

            ws.onText { _, text in
                if text == "ping" {
                    ws.send("pong")
                }
            }
        }
    }
}

private struct ServerVersionMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .server, value: AppVersion.serverHeaderValue)
        return response
    }
}

private struct DebugRequestLoggingMiddleware: AsyncMiddleware {
    let configService: ConfigService

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let debugEnabled = await configService.currentAppConfig().debug
        let response = try await next.respond(to: request)

        guard debugEnabled else {
            return response
        }

        let query = request.url.query.map { "?\($0)" } ?? ""
        print("[debug][http] \(request.method.rawValue) \(request.url.path)\(query) -> \(response.status.code)")
        return response
    }
}

private final class GracefulShutdownHandler {
    private let application: Application
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var didRequestShutdown = false

    init(application: Application) {
        self.application = application
    }

    func install() {
        sources = [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.requestShutdown()
            }
            source.resume()
            return source
        }
    }

    func cancel() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    private func requestShutdown() {
        lock.lock()
        let shouldShutdown = didRequestShutdown == false
        didRequestShutdown = true
        lock.unlock()

        guard shouldShutdown else {
            return
        }

        application.shutdown()
    }
}

private struct PIDFileScope {
    let url: URL?

    init(url: URL?) throws {
        self.url = url
        guard let url else {
            return
        }
        try String(ProcessInfo.processInfo.processIdentifier).write(to: url, atomically: true, encoding: .utf8)
    }

    func cleanup() throws {
        guard let url else {
            return
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private struct ServerBootstrap: @unchecked Sendable {
    let configService: ConfigService
    let toolRuntime: ToolRuntime
    let conversationService: ConversationService
    let eventHub: SessionEventHub
    let apfelManager: ApfelManager
    let apfelUpdateService: ApfelUpdateService
    let apfelMaintenanceService: ApfelMaintenanceService
    let remoteControlService: RemoteControlService
    let telegramRemoteControlProvider: TelegramRemoteControlProvider
    let memoryStore: MemoryStore
    let installStateStore: InstallStateStore

    static func make() async throws -> ServerBootstrap {
        let directories = try AppDirectories()
        try directories.bootstrap()

        let settingsStore = SettingsStore(directories: directories)
        let configService = try ConfigService(settingsStore: settingsStore)
        let config = await configService.currentAppConfig()
        let installStateStore = InstallStateStore(directories: directories)
        _ = try? installStateStore.refreshRuntimeState(installSource: AppInstallSourceDetector.detectCurrentInstallSource())

        let memoryStore = MemoryStore(directories: directories)
        try memoryStore.open()

        if config.memoryEnabled {
            try memoryStore.upsertFact(key: "assistant_name", value: config.assistantName, source: "server")
            try memoryStore.upsertFact(key: "user_name", value: config.userName, source: "server")
            try memoryStore.upsertFact(key: "approval_mode", value: config.approvalMode.rawValue, source: "server")
            try memoryStore.upsertFact(key: "memory_enabled", value: String(config.memoryEnabled), source: "server")
        }

        let apfelManager = ApfelManager(config: config)
        _ = try await apfelManager.ensureServerRunning()
        let apfelUpdateService = ApfelUpdateService(apfelManager: apfelManager)
        let apfelMaintenanceService = ApfelMaintenanceService(
            apfelManager: apfelManager,
            updateService: apfelUpdateService
        )
        await apfelUpdateService.start()

        let toolRuntime = try ToolRuntime()
        let eventHub = SessionEventHub()
        let conversationService = ConversationService(
            memoryStore: memoryStore,
            configService: configService,
            modelClient: ModelClient(),
            toolRuntime: toolRuntime,
            eventHub: eventHub,
            apfelMaintenanceService: apfelMaintenanceService
        )
        let commandService = CommandService(
            configService: configService,
            conversationService: conversationService,
            apfelUpdateService: apfelUpdateService,
            apfelMaintenanceService: apfelMaintenanceService
        )
        let remoteControlSettingsStore = RemoteControlSettingsStore(directories: directories)
        let remoteControlService = try RemoteControlService(settingsStore: remoteControlSettingsStore)
        let telegramRemoteControlProvider = TelegramRemoteControlProvider(
            remoteControlService: remoteControlService,
            commandService: commandService,
            conversationService: conversationService,
            memoryStore: memoryStore,
            debugEnabled: { await configService.currentAppConfig().debug }
        )
        telegramRemoteControlProvider.start()
        return ServerBootstrap(
            configService: configService,
            toolRuntime: toolRuntime,
            conversationService: conversationService,
            eventHub: eventHub,
            apfelManager: apfelManager,
            apfelUpdateService: apfelUpdateService,
            apfelMaintenanceService: apfelMaintenanceService,
            remoteControlService: remoteControlService,
            telegramRemoteControlProvider: telegramRemoteControlProvider,
            memoryStore: memoryStore,
            installStateStore: installStateStore
        )
    }
}
