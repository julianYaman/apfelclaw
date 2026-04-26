import Foundation
import SQLite3

public struct SessionRecord: Codable, Sendable {
    public let id: Int64
    public let title: String
    public let createdAt: String
}

public struct ToolCallRecord: Codable, Sendable {
    public let toolName: String
    public let approved: Bool
    public let payload: String
    public let createdAt: String
}

public final class MemoryStore: @unchecked Sendable {
    private let databaseURL: URL
    private var db: OpaquePointer?

    public init(directories: AppDirectories) {
        self.databaseURL = directories.configRoot.appendingPathComponent("memory.sqlite")
    }

    deinit {
        sqlite3_close(db)
    }

    public func open() throws {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw AppError.message("Unable to open SQLite database at \(databaseURL.path).")
        }

        try execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS summaries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            summary TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS facts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS tool_calls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            tool_name TEXT NOT NULL,
            approved INTEGER NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS remote_session_mappings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            session_id INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            UNIQUE(provider, remote_id),
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );
        """)
    }

    @discardableResult
    public func createSession(title: String) throws -> Int64 {
        let sql = "INSERT INTO sessions (title, created_at) VALUES (?, ?);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, title, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, Self.timestamp, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to create session.")
        }

        return sqlite3_last_insert_rowid(db)
    }

    public func appendMessage(sessionID: Int64, role: String, content: String) throws {
        let sql = "INSERT INTO messages (session_id, role, content, created_at) VALUES (?, ?, ?, ?);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)
        sqlite3_bind_text(statement, 2, role, -1, transientDestructor)
        sqlite3_bind_text(statement, 3, content, -1, transientDestructor)
        sqlite3_bind_text(statement, 4, Self.timestamp, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to append a message.")
        }
    }

    public func listSessions(limit: Int = 10) throws -> [SessionRecord] {
        let sql = "SELECT id, title, created_at FROM sessions ORDER BY id DESC LIMIT ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var sessions: [SessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            sessions.append(
                SessionRecord(
                    id: sqlite3_column_int64(statement, 0),
                    title: Self.columnText(statement, index: 1),
                    createdAt: Self.columnText(statement, index: 2)
                )
            )
        }
        return sessions
    }

    public func sessionCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM sessions;")
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AppError.message("Unable to count sessions.")
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    public func listMessages(sessionID: Int64, limit: Int = 20) throws -> [(role: String, content: String)] {
        let sql = """
        SELECT role, content FROM messages
        WHERE session_id = ?
        ORDER BY id DESC
        LIMIT ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var messages: [(role: String, content: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            messages.append((
                role: Self.columnText(statement, index: 0),
                content: Self.columnText(statement, index: 1)
            ))
        }

        return messages.reversed()
    }

    public func upsertFact(key: String, value: String, source: String) throws {
        let sql = "INSERT INTO facts (key, value, source, created_at) VALUES (?, ?, ?, ?);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, value, -1, transientDestructor)
        sqlite3_bind_text(statement, 3, source, -1, transientDestructor)
        sqlite3_bind_text(statement, 4, Self.timestamp, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to persist fact '\(key)'.")
        }
    }

    public func replaceSessionSummary(sessionID: Int64, summary: String) throws {
        try execute("DELETE FROM summaries WHERE session_id = \(sessionID);")

        let sql = "INSERT INTO summaries (session_id, summary, created_at) VALUES (?, ?, ?);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)
        sqlite3_bind_text(statement, 2, summary, -1, transientDestructor)
        sqlite3_bind_text(statement, 3, Self.timestamp, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to persist session summary.")
        }
    }

    public func deleteSessionSummary(sessionID: Int64) throws {
        let sql = "DELETE FROM summaries WHERE session_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to delete session summary.")
        }
    }

    public func latestSummary(sessionID: Int64) throws -> String? {
        let sql = "SELECT summary FROM summaries WHERE session_id = ? ORDER BY id DESC LIMIT 1;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return Self.columnText(statement, index: 0)
    }

    public func logToolCall(sessionID: Int64, toolName: String, approved: Bool, payload: String) throws {
        let sql = "INSERT INTO tool_calls (session_id, tool_name, approved, payload, created_at) VALUES (?, ?, ?, ?, ?);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)
        sqlite3_bind_text(statement, 2, toolName, -1, transientDestructor)
        sqlite3_bind_int(statement, 3, approved ? 1 : 0)
        sqlite3_bind_text(statement, 4, payload, -1, transientDestructor)
        sqlite3_bind_text(statement, 5, Self.timestamp, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to log tool call.")
        }
    }

    public func latestToolCall(sessionID: Int64) throws -> ToolCallRecord? {
        let sql = """
        SELECT tool_name, approved, payload, created_at
        FROM tool_calls
        WHERE session_id = ?
        ORDER BY id DESC
        LIMIT 1;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return ToolCallRecord(
            toolName: Self.columnText(statement, index: 0),
            approved: sqlite3_column_int(statement, 1) == 1,
            payload: Self.columnText(statement, index: 2),
            createdAt: Self.columnText(statement, index: 3)
        )
    }

    public func hasApprovedToolCall(sessionID: Int64, toolName: String) throws -> Bool {
        let sql = """
        SELECT 1
        FROM tool_calls
        WHERE session_id = ? AND tool_name = ? AND approved = 1
        LIMIT 1;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sessionID)
        sqlite3_bind_text(statement, 2, toolName, -1, transientDestructor)

        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func remoteSessionID(provider: String, remoteID: String) throws -> Int64? {
        let sql = """
        SELECT session_id
        FROM remote_session_mappings
        WHERE provider = ? AND remote_id = ?
        LIMIT 1;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, provider, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, remoteID, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_int64(statement, 0)
    }

    public func upsertRemoteSession(provider: String, remoteID: String, sessionID: Int64) throws {
        let sql = """
        INSERT INTO remote_session_mappings (provider, remote_id, session_id, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(provider, remote_id)
        DO UPDATE SET session_id = excluded.session_id;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, provider, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, remoteID, -1, transientDestructor)
        sqlite3_bind_int64(statement, 3, sessionID)
        sqlite3_bind_text(statement, 4, Self.timestamp, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to upsert remote session mapping.")
        }
    }

    public func deleteRemoteSessions(provider: String) throws {
        let sql = "DELETE FROM remote_session_mappings WHERE provider = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, provider, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message("Unable to delete remote session mappings.")
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw AppError.message("SQLite execution failed: \(lastErrorMessage)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppError.message("SQLite prepare failed: \(lastErrorMessage)")
        }
        return statement
    }

    private var lastErrorMessage: String {
        guard let db, let pointer = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: pointer)
    }

    private static var timestamp: String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: pointer)
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
