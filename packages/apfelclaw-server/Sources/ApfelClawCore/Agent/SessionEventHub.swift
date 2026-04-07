import Foundation

public struct StreamEvent: Codable, Sendable {
    public let type: String
    public let sessionID: Int64
    public let message: SessionMessage?
    public let toolCall: ToolExecutionSummary?
    public let error: String?

    public init(
        type: String,
        sessionID: Int64,
        message: SessionMessage? = nil,
        toolCall: ToolExecutionSummary? = nil,
        error: String? = nil
    ) {
        self.type = type
        self.sessionID = sessionID
        self.message = message
        self.toolCall = toolCall
        self.error = error
    }
}

public final class SessionEventHub: @unchecked Sendable {
    public typealias Sink = (String) -> Void

    private var sinks: [Int64: [UUID: Sink]] = [:]
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func subscribe(sessionID: Int64, sink: @escaping Sink) -> UUID {
        lock.lock()
        defer { lock.unlock() }

        let id = UUID()
        var current = sinks[sessionID] ?? [:]
        current[id] = sink
        sinks[sessionID] = current
        return id
    }

    public func unsubscribe(sessionID: Int64, id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard var current = sinks[sessionID] else {
            return
        }
        current.removeValue(forKey: id)
        sinks[sessionID] = current.isEmpty ? nil : current
    }

    public func publish(_ event: StreamEvent) {
        let current: [Sink]
        lock.lock()
        current = Array((sinks[event.sessionID] ?? [:]).values)
        lock.unlock()

        guard current.isEmpty == false else {
            return
        }

        guard let data = try? encoder.encode(event), let payload = String(data: data, encoding: .utf8) else {
            return
        }

        for sink in current {
            sink(payload)
        }
    }
}
