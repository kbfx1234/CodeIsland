import Foundation
import SQLite3
import CodeIslandCore

/// OpenCode sessions, and Xiaomi MiMo Code's (the same store): running
/// processes matched to sessions in the store's SQLite database.
enum OpenCodeDiscovery {
    /// `storeSessionId`, when the card's key names the store row, is read
    /// first; the cwd match is the fallback.
    static func readModelFromOpenCodeStore(
        cwd: String?,
        processStart: Date?,
        dbPath: String = openCodeDatabasePath(),
        rootSessionsOnly: Bool = false,
        storeSessionId: String? = nil
    ) -> String? {
        return SQLiteReader.withSQLiteDatabase(at: dbPath) { db in
            if let storeSessionId,
               let model = readRecentFromOpenCodeSession(db: db, sessionId: storeSessionId).0 {
                return model
            }
            guard let cwd, let session = findRecentOpenCodeSession(
                in: db, cwd: cwd, after: processStart, rootSessionsOnly: rootSessionsOnly
            ) else {
                return nil
            }
            return readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId).0
        }
    }

    static func openCodeDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    /// MiMo Code keeps OpenCode's SQLite layout under its own name; release
    /// builds (channels latest / beta / prod) write `mimocode.db`.
    static func mimoDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/mimocode/mimocode.db").path
    }

    static func findActiveOpenCodeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        findActiveOpenCodeStoreSessions(
            pids: AgentProcessFinder.findOpenCodePids(candidatePids: candidatePids),
            dbPath: openCodeDatabasePath(),
            source: "opencode",
            sessionIdPrefix: "",
            rootSessionsOnly: false
        )
    }

    /// Running `mimo` CLIs, matched to their session in MiMo Code's store.
    /// Keyed `mimo-<id>`, the id the plugin reports, so a session found here
    /// and the plugin's events for it land on one card.
    static func findActiveMimoSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        findActiveOpenCodeStoreSessions(
            pids: AgentProcessFinder.findMimoPids(candidatePids: candidatePids),
            dbPath: mimoDatabasePath(),
            source: "mimo",
            sessionIdPrefix: "mimo-",
            rootSessionsOnly: true
        )
    }

    private static func findActiveOpenCodeStoreSessions(
        pids: [pid_t],
        dbPath: String,
        source: String,
        sessionIdPrefix: String,
        rootSessionsOnly: Bool
    ) -> [DiscoveredSession] {
        guard !pids.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        return SQLiteReader.withSQLiteDatabase(at: dbPath) { db in
            var results: [DiscoveredSession] = []
            var seenSessionIds: Set<String> = []

            for pid in pids {
                guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { continue }
                let processStart = ProcessTable.getProcessStartTime(pid)
                guard let session = findRecentOpenCodeSession(
                    in: db, cwd: cwd, after: processStart, rootSessionsOnly: rootSessionsOnly
                ) else { continue }
                guard !seenSessionIds.contains(session.sessionId) else { continue }
                seenSessionIds.insert(session.sessionId)

                let (model, messages) = readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId)
                results.append(DiscoveredSession(
                    sessionId: sessionIdPrefix + session.sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: model,
                    pid: pid,
                    modifiedAt: session.modifiedAt,
                    recentMessages: messages,
                    source: source
                ))
            }

            return results
        } ?? []
    }

    /// `rootSessionsOnly` skips child sessions (`parent_id` set): MiMo Code
    /// spawns subagent sessions in the same directory, and while one runs it
    /// is the most recently updated row — but it is never the CLI's own.
    static func findRecentOpenCodeSession(
        in db: OpaquePointer,
        cwd: String,
        after processStart: Date?,
        rootSessionsOnly: Bool = false
    ) -> (sessionId: String, modifiedAt: Date)? {
        let rootFilter = rootSessionsOnly ? "AND parent_id IS NULL" : ""
        let sql = """
            SELECT id, time_updated
            FROM session
            WHERE time_archived IS NULL
              \(rootFilter)
              AND (
                directory = ?
                OR EXISTS (
                    SELECT 1
                    FROM message m
                    WHERE m.session_id = session.id
                      AND json_extract(m.data, '$.path.cwd') = ?
                )
              )
            ORDER BY time_updated DESC
            LIMIT 20;
            """
        guard let statement = SQLiteReader.prepareSQLiteStatement(db: db, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        SQLiteReader.bindSQLiteText(cwd, to: statement, index: 1)
        SQLiteReader.bindSQLiteText(cwd, to: statement, index: 2)

        let minUpdatedAtMs = processStart.map { Int64($0.timeIntervalSince1970 * 1000) - 10_000 }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionId = SQLiteReader.sqliteColumnString(statement, index: 0) else { continue }
            let updatedAtMs = sqlite3_column_int64(statement, 1)
            if let minUpdatedAtMs, updatedAtMs < minUpdatedAtMs { continue }
            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000)
            return (sessionId, modifiedAt)
        }
        return nil
    }

    private static func readRecentFromOpenCodeSession(
        db: OpaquePointer,
        sessionId: String
    ) -> (String?, [ChatMessage]) {
        var model: String?

        if let messageStatement = SQLiteReader.prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT data
                FROM message
                WHERE session_id = ?
                ORDER BY time_updated DESC
                LIMIT 12;
                """
        ) {
            defer { sqlite3_finalize(messageStatement) }
            SQLiteReader.bindSQLiteText(sessionId, to: messageStatement, index: 1)
            while sqlite3_step(messageStatement) == SQLITE_ROW {
                guard model == nil,
                      let data = SQLiteReader.sqliteColumnString(messageStatement, index: 0),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                model = json["modelID"] as? String
                if model == nil,
                   let modelInfo = json["model"] as? [String: Any] {
                    model = modelInfo["modelID"] as? String
                }
            }
        }

        var seenMessageIds: Set<String> = []
        var combined: [(Int64, ChatMessage)] = []
        if let partStatement = SQLiteReader.prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT p.message_id, json_extract(m.data, '$.role'), p.time_created, p.data
                FROM part p
                JOIN message m ON m.id = p.message_id
                WHERE p.session_id = ?
                ORDER BY p.time_created DESC
                LIMIT 80;
                """
        ) {
            defer { sqlite3_finalize(partStatement) }
            SQLiteReader.bindSQLiteText(sessionId, to: partStatement, index: 1)
            while sqlite3_step(partStatement) == SQLITE_ROW {
                guard let messageId = SQLiteReader.sqliteColumnString(partStatement, index: 0),
                      !seenMessageIds.contains(messageId),
                      let role = SQLiteReader.sqliteColumnString(partStatement, index: 1),
                      let data = SQLiteReader.sqliteColumnString(partStatement, index: 3),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      json["type"] as? String == "text",
                      let text = json["text"] as? String, !text.isEmpty else { continue }

                let isUser = role == "user"
                guard isUser || role == "assistant" else { continue }

                seenMessageIds.insert(messageId)
                combined.append((sqlite3_column_int64(partStatement, 2), ChatMessage(isUser: isUser, text: text)))
            }
        }

        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }
}
