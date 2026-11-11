import Foundation
import SQLite3
import CodeIslandCore

/// Grok CLI sessions: running processes matched to the sessions each Grok
/// root indexes and keeps under `sessions/`.
enum GrokDiscovery {
    static func readModelFromGrokStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        return findRecentGrokSession(cwd: cwd, after: processStart)?.model
    }

    /// Grok percent-encodes the full cwd into a single directory component,
    /// including `/` as `%2F` (for example `/Users/me` -> `%2FUsers%2Fme`).
    static func grokEncodedCwd(_ cwd: String) -> String? {
        GrokSessionPaths.encodedCwd(cwd)
    }

    struct GrokSessionCandidate {
        let sessionId: String
        /// `sessions/<encoded-cwd>/<id>`; nil when only Grok's search index
        /// knows the session, so there is no transcript to read or tail.
        let directory: String?
        let model: String?
        let createdAt: Date?
        let activityAt: Date
    }

    /// Grok mints UUIDv7 session ids (a client may pass its own with `-s`),
    /// whose leading 48 bits are the creation time in Unix milliseconds. That
    /// stands in for `summary.json`'s `created_at` when it is missing, and is
    /// the only creation time for a session known only to the search index.
    static func grokSessionCreationDate(fromSessionId sessionId: String) -> Date? {
        guard let uuid = UUID(uuidString: sessionId)?.uuid,
              uuid.6 >> 4 == 7,
              uuid.8 & 0xC0 == 0x80 else { return nil }
        let milliseconds = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5]
            .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// Sessions that Grok's search index (`sessions/session_search.sqlite`,
    /// table `session_docs`) records for `cwd`, most recently updated first.
    /// Grok writes the index live in WAL mode, so it is opened read-only
    /// through SQLite (never `immutable`, which would skip the WAL), and an
    /// unexpected schema yields no rows rather than a guess.
    static func grokIndexedSessions(
        databasePath: String,
        cwd: String,
        limit: Int = 50
    ) -> [(sessionId: String, updatedAt: Date)] {
        SQLiteReader.withSQLiteDatabase(at: databasePath) { db -> [(sessionId: String, updatedAt: Date)]? in
            let columns = SQLiteReader.sqliteTableColumns(db: db, tableName: "session_docs")
            guard columns.isSuperset(of: ["session_id", "cwd", "updated_at"]),
                  let statement = SQLiteReader.prepareSQLiteStatement(
                    db: db,
                    sql: """
                        SELECT session_id, updated_at
                        FROM session_docs
                        WHERE cwd = ?
                        ORDER BY updated_at DESC
                        LIMIT ?;
                        """
                  ) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            SQLiteReader.bindSQLiteText(cwd, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(clamping: limit))

            var rows: [(sessionId: String, updatedAt: Date)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionId = SQLiteReader.sqliteColumnString(statement, index: 0),
                      !sessionId.isEmpty else { continue }
                let raw = sqlite3_column_int64(statement, 1)
                guard raw > 0 else { continue }
                // Schema v4 stores Unix seconds; tolerate milliseconds.
                let seconds = raw > 100_000_000_000 ? Double(raw) / 1000 : Double(raw)
                rows.append((sessionId, Date(timeIntervalSince1970: seconds)))
            }
            return rows
        } ?? []
    }

    /// Score a metadata session against a live Grok process. Grok's native
    /// hooks are authoritative once a turn starts; discovery is only a recovery
    /// path, so it must prefer missing a late `/new` over attaching a completed
    /// one-shot session to an unrelated long-lived process in the same cwd.
    static func grokSessionProcessMatchScore(
        createdAt: Date?,
        activityAt: Date,
        processStart: Date?,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let processStart else {
            let age = now.timeIntervalSince(activityAt)
            guard age >= -10, age <= 30 else { return nil }
            return 1_000 + max(age, 0)
        }

        guard activityAt >= processStart.addingTimeInterval(-10) else { return nil }

        if let createdAt {
            let creationDelta = createdAt.timeIntervalSince(processStart)
            if abs(creationDelta) <= 120 {
                return abs(creationDelta)
            }

            // A resumed session was created before this process. Accept it only
            // while its first recovered activity is still close to launch.
            if createdAt < processStart {
                let activityDelta = activityAt.timeIntervalSince(processStart)
                if activityDelta >= -10, activityDelta <= 120 {
                    return 300 + abs(activityDelta)
                }
            }
            return nil
        }

        let activityDelta = activityAt.timeIntervalSince(processStart)
        guard activityDelta >= -10, activityDelta <= 120 else { return nil }
        return 600 + abs(activityDelta)
    }

    /// Produce a one-to-one mapping for Grok processes that share a cwd. The
    /// newest viable session is assigned first and prefers its closest process
    /// start. An augmenting path may move an earlier assignment to its next-best
    /// process when that is required to keep another viable session visible.
    static func matchGrokSessionsToProcesses(
        processes: [(pid: pid_t, startedAt: Date?)],
        sessions: [(id: String, createdAt: Date?, activityAt: Date)],
        now: Date = Date()
    ) -> [String: pid_t] {
        typealias Edge = (pid: pid_t, score: TimeInterval)
        let orderedSessions = sessions.sorted { lhs, rhs in
            if lhs.activityAt != rhs.activityAt {
                return lhs.activityAt > rhs.activityAt
            }
            return lhs.id < rhs.id
        }
        var edgesBySession: [String: [Edge]] = [:]

        for session in orderedSessions where edgesBySession[session.id] == nil {
            edgesBySession[session.id] = processes.compactMap { process in
                guard let score = grokSessionProcessMatchScore(
                    createdAt: session.createdAt,
                    activityAt: session.activityAt,
                    processStart: process.startedAt,
                    now: now
                ) else { return nil }
                return (process.pid, score)
            }.sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.pid < rhs.pid
            }
        }

        var sessionByPid: [pid_t: String] = [:]

        func assign(_ sessionId: String, visitedPids: inout Set<pid_t>) -> Bool {
            guard let edges = edgesBySession[sessionId] else { return false }

            // Preserve earlier (newer) choices when this session has an unused
            // viable PID of its own.
            if let freeEdge = edges.first(where: {
                !visitedPids.contains($0.pid) && sessionByPid[$0.pid] == nil
            }) {
                visitedPids.insert(freeEdge.pid)
                sessionByPid[freeEdge.pid] = sessionId
                return true
            }

            // Otherwise find an augmenting path: move the current owner to its
            // next-best PID, then claim the newly released one.
            for edge in edges where visitedPids.insert(edge.pid).inserted {
                guard let displacedSession = sessionByPid[edge.pid] else {
                    sessionByPid[edge.pid] = sessionId
                    return true
                }
                if assign(displacedSession, visitedPids: &visitedPids) {
                    sessionByPid[edge.pid] = sessionId
                    return true
                }
            }
            return false
        }

        var attemptedSessions: Set<String> = []
        for session in orderedSessions where attemptedSessions.insert(session.id).inserted {
            var visitedPids: Set<pid_t> = []
            _ = assign(session.id, visitedPids: &visitedPids)
        }

        return Dictionary(uniqueKeysWithValues: sessionByPid.map { ($0.value, $0.key) })
    }

    /// Grok sessions recorded for `cwd`. The per-session directories are
    /// Grok's session store and carry the transcript; `session_search.sqlite`
    /// is Grok's search index over sessions and only adds ones without a
    /// readable directory here (a cwd too long for one path component is
    /// stored under a slug+hash name, and a machine can hold sessions whose
    /// directories are gone). Both layouts can coexist on one machine.
    static func grokSessionCandidates(
        cwd: String,
        sessionsRoot: String = "\(ConfigInstaller.grokHome())/sessions",
        includeIndex: Bool = true,
        fm: FileManager = .default
    ) -> [GrokSessionCandidate] {
        var candidates = grokDirectorySessionCandidates(cwd: cwd, sessionsRoot: sessionsRoot, fm: fm)
        let indexPath = "\(sessionsRoot)/session_search.sqlite"
        guard includeIndex, fm.fileExists(atPath: indexPath) else { return candidates }

        let known = Set(candidates.map(\.sessionId))
        for row in grokIndexedSessions(databasePath: indexPath, cwd: cwd)
        where !known.contains(row.sessionId) {
            candidates.append(GrokSessionCandidate(
                sessionId: row.sessionId,
                directory: nil,
                model: nil,
                createdAt: grokSessionCreationDate(fromSessionId: row.sessionId),
                activityAt: row.updatedAt
            ))
        }
        return candidates
    }

    private static func grokDirectorySessionCandidates(
        cwd: String,
        sessionsRoot: String,
        fm: FileManager
    ) -> [GrokSessionCandidate] {
        guard let encodedCwd = grokEncodedCwd(cwd) else { return [] }
        let cwdDirectory = "\(sessionsRoot)/\(encodedCwd)"
        guard let sessionDirectories = try? fm.contentsOfDirectory(atPath: cwdDirectory) else { return [] }

        var candidates: [GrokSessionCandidate] = []
        for directoryName in sessionDirectories {
            let directory = "\(cwdDirectory)/\(directoryName)"
            let summaryPath = "\(directory)/summary.json"
            guard let data = fm.contents(atPath: summaryPath),
                  let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = summary["info"] as? [String: Any],
                  let summaryCwd = info["cwd"] as? String,
                  summaryCwd == cwd else { continue }

            let sessionId = (info["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directoryName
            let createdAt = (summary["created_at"] as? String).flatMap(SessionDiscovery.parseISO8601Timestamp)
                ?? grokSessionCreationDate(fromSessionId: sessionId)
            let timestamps = ["last_active_at", "updated_at", "created_at"]
                .compactMap { summary[$0] as? String }
                .compactMap(SessionDiscovery.parseISO8601Timestamp)
            var activityAt = timestamps.max() ?? .distantPast

            // File mtimes catch a turn that has started writing events before
            // summary.json has been refreshed.
            for filename in ["summary.json", "events.jsonl", "updates.jsonl", "chat_history.jsonl"] {
                let path = "\(directory)/\(filename)"
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let modified = attrs[.modificationDate] as? Date,
                   modified > activityAt {
                    activityAt = modified
                }
            }

            candidates.append(GrokSessionCandidate(
                sessionId: sessionId,
                directory: directory,
                model: (summary["current_model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                createdAt: createdAt,
                activityAt: activityAt
            ))
        }
        return candidates
    }

    private static func findRecentGrokSession(
        cwd: String,
        after processStart: Date?,
        fm: FileManager = .default
    ) -> GrokSessionCandidate? {
        // Model backfill runs on the main actor, and the index has no model.
        ConfigInstaller.grokHomes()
            .flatMap { grokSessionCandidates(cwd: cwd, sessionsRoot: "\($0)/sessions", includeIndex: false, fm: fm) }
            .filter {
                grokSessionProcessMatchScore(
                    createdAt: $0.createdAt,
                    activityAt: $0.activityAt,
                    processStart: processStart
                ) != nil
            }
            .max { $0.activityAt < $1.activityAt }
    }

    static func findActiveGrokSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let grokPids = AgentProcessFinder.findGrokPids(candidatePids: candidatePids)
        guard !grokPids.isEmpty else { return [] }

        let fm = FileManager.default
        let liveProcesses = grokPids.compactMap { pid -> GrokDiscoveryProcess? in
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { return nil }
            return GrokDiscoveryProcess(pid: pid, cwd: cwd, startedAt: ProcessTable.getProcessStartTime(pid))
        }
        // Processes compete for sessions only within one root (their
        // GROK_HOME, grouped by identity) and one cwd: two accounts working in
        // the same project keep separate stores. See ConfigRootDiscovery for
        // processes whose environment cannot be read and for paused roots.
        let scan = SessionDiscovery.configRootScan(for: .grok)
        return ConfigRootDiscovery.run(
            processes: liveProcesses,
            lookup: { scan.lookup(pid: $0.pid) },
            fallbackRoots: scan.fallbackRoots,
            discover: { root, processes, claimed in
                grokSessions(for: processes, sessionsRoot: "\(root)/sessions", excluding: claimed, fm: fm)
            },
            sessionId: \.sessionId,
            belongsTo: { $0.pid == $1.pid }
        )
    }

    struct GrokDiscoveryProcess {
        let pid: pid_t
        let cwd: String
        let startedAt: Date?
    }

    /// Grok sessions under one sessions root for `processes`, matched per cwd.
    /// Sessions in `claimed` (already taken by another root's processes) are
    /// not offered, so the matcher can hand a process its next-best one.
    private static func grokSessions(
        for processes: [GrokDiscoveryProcess],
        sessionsRoot: String,
        excluding claimed: Set<String>,
        fm: FileManager
    ) -> [DiscoveredSession] {
        var results: [DiscoveredSession] = []
        for (cwd, sameCwd) in Dictionary(grouping: processes, by: \.cwd) {
            let candidates = grokSessionCandidates(cwd: cwd, sessionsRoot: sessionsRoot, fm: fm)
                .filter { !claimed.contains($0.sessionId) }
            let assignments = matchGrokSessionsToProcesses(
                processes: sameCwd.map { ($0.pid, $0.startedAt) },
                sessions: candidates.map { ($0.sessionId, $0.createdAt, $0.activityAt) }
            )

            for candidate in candidates {
                guard let pid = assignments[candidate.sessionId] else { continue }
                // Index-only sessions have no transcript; never point the
                // tailer at a file that is not there.
                let chatPath = candidate.directory
                    .map { "\($0)/chat_history.jsonl" }
                    .flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
                let messages = chatPath.map { ClaudeDiscovery.readRecentFromTranscript(path: $0).1 } ?? []
                results.append(grokDiscoveredSession(
                    sessionId: candidate.sessionId,
                    cwd: cwd,
                    model: candidate.model,
                    pid: pid,
                    modifiedAt: candidate.activityAt,
                    recentMessages: messages,
                    transcriptPath: chatPath
                ))
            }
        }
        return results
    }

    /// Grok hooks and Grok discovery both key a card by Grok's own session id,
    /// so the discovered id doubles as the provider id. Carrying it stops the
    /// same-PID dedup in `integrateDiscovered` from folding a different Grok
    /// session — such as the one `/resume` just loaded — into an existing card
    /// and rewriting that card's identity, transcript and messages (#318).
    static func grokDiscoveredSession(
        sessionId: String,
        cwd: String,
        model: String?,
        pid: pid_t,
        modifiedAt: Date,
        recentMessages: [ChatMessage],
        transcriptPath: String?
    ) -> DiscoveredSession {
        DiscoveredSession(
            sessionId: sessionId,
            cwd: cwd,
            tty: nil,
            model: model,
            pid: pid,
            modifiedAt: modifiedAt,
            recentMessages: recentMessages,
            source: "grok",
            transcriptPath: transcriptPath,
            providerSessionId: sessionId
        )
    }
}
