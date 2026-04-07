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

@main
struct ApfelClawServerMain {
    static func main() async throws {
        let bootstrap = try await ServerBootstrap.make()
        let app = try await Application.make(.development)
        let signalHandler = GracefulShutdownHandler(application: app)

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 4242
        app.middleware.use(ServerVersionMiddleware())
        app.middleware.use(DebugRequestLoggingMiddleware(configService: bootstrap.configService))

        try routes(app: app, bootstrap: bootstrap)
        signalHandler.install()
        do {
            try await app.execute()
            signalHandler.cancel()
            bootstrap.apfelManager.shutdownIfOwned()
            try? await app.asyncShutdown()
        } catch {
            signalHandler.cancel()
            bootstrap.apfelManager.shutdownIfOwned()
            try? await app.asyncShutdown()
            throw error
        }
    }

    private static func routes(app: Application, bootstrap: ServerBootstrap) throws {
        app.get("health") { _ in
            ["status": "ok"]
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
                autoApproveTools: body.autoApproveTools ?? true
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

private struct ServerBootstrap {
    let configService: ConfigService
    let toolRuntime: ToolRuntime
    let conversationService: ConversationService
    let eventHub: SessionEventHub
    let apfelManager: ApfelManager

    static func make() async throws -> ServerBootstrap {
        let directories = try AppDirectories()
        try directories.bootstrap()

        let settingsStore = SettingsStore(directories: directories)
        let configService = try ConfigService(settingsStore: settingsStore)
        let config = await configService.currentAppConfig()

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

        let toolRuntime = try ToolRuntime()
        let eventHub = SessionEventHub()
        let conversationService = ConversationService(
            memoryStore: memoryStore,
            configService: configService,
            modelClient: ModelClient(),
            toolRuntime: toolRuntime,
            eventHub: eventHub
        )
        return ServerBootstrap(
            configService: configService,
            toolRuntime: toolRuntime,
            conversationService: conversationService,
            eventHub: eventHub,
            apfelManager: apfelManager
        )
    }
}
