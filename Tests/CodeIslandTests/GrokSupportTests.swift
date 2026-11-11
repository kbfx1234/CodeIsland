import XCTest
import SQLite3
@testable import CodeIsland
@testable import CodeIslandCore

final class GrokSupportTests: XCTestCase {
    func testSourceNormalizationAndLabel() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("grok"), "grok")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("Grok CLI"), "grok")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("grok-build"), "grok")

        var snapshot = SessionSnapshot()
        snapshot.source = "grok"
        XCTAssertEqual(snapshot.sourceLabel, "Grok CLI")
    }

    func testGrokExecutableResolverAcceptsManagedAndPathInstalls() {
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/Users/test/.grok/downloads/grok-0.2.106-macos-aarch64",
            source: "grok"
        ))
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/opt/homebrew/bin/grok",
            source: "grok-cli"
        ))
        XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath(
            "/Applications/Browser.app/Contents/MacOS/grok-helper",
            source: "grok"
        ))
    }

    func testGrokEventAliasesReachTerminalStates() {
        XCTAssertEqual(EventNormalizer.normalize("permission_denied"), "PermissionDenied")
        XCTAssertEqual(EventNormalizer.normalize("stop_failure"), "Stop")
        XCTAssertEqual(EventNormalizer.normalize("StopFailure"), "Stop")
    }

    func testGrokCLIUsesEveryManagedHookEvent() throws {
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "grok" })
        XCTAssertEqual(cli.events.map(\.0), GrokHookForwardingPolicy.managedHookEvents)
    }

    func testGrokEncodedCwdEscapesSlashesAndSpaces() {
        XCTAssertEqual(
            GrokDiscovery.grokEncodedCwd("/Users/test/My Project"),
            "%2FUsers%2Ftest%2FMy%20Project"
        )
    }

    func testGrokProcessMatchingRejectsLateSessionFromOlderProcess() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldProcessStart = now.addingTimeInterval(-35 * 60)
        let newProcessStart = now.addingTimeInterval(-5)
        let sessionCreatedAt = now.addingTimeInterval(-4)

        XCTAssertNil(GrokDiscovery.grokSessionProcessMatchScore(
            createdAt: sessionCreatedAt,
            activityAt: now,
            processStart: oldProcessStart,
            now: now
        ))
        XCTAssertNotNil(GrokDiscovery.grokSessionProcessMatchScore(
            createdAt: sessionCreatedAt,
            activityAt: now,
            processStart: newProcessStart,
            now: now
        ))
    }

    func testGrokProcessMatchingIsOneToOneForParallelSameCwdSessions() {
        let base = Date(timeIntervalSince1970: 20_000)
        let mapping = GrokDiscovery.matchGrokSessionsToProcesses(
            processes: [
                (pid: 101, startedAt: base),
                (pid: 202, startedAt: base.addingTimeInterval(30)),
            ],
            sessions: [
                (
                    id: "first",
                    createdAt: base.addingTimeInterval(2),
                    activityAt: base.addingTimeInterval(40)
                ),
                (
                    id: "second",
                    createdAt: base.addingTimeInterval(32),
                    activityAt: base.addingTimeInterval(50)
                ),
            ],
            now: base.addingTimeInterval(60)
        )

        XCTAssertEqual(mapping["first"], 101)
        XCTAssertEqual(mapping["second"], 202)
        XCTAssertEqual(Set(mapping.values).count, mapping.count)
    }

    func testGrokProcessMatchingUsesAugmentingPathToKeepEveryViableSession() {
        let base = Date(timeIntervalSince1970: 30_000)
        let mapping = GrokDiscovery.matchGrokSessionsToProcesses(
            processes: [
                (pid: 101, startedAt: base),
                (pid: 202, startedAt: base.addingTimeInterval(100)),
            ],
            sessions: [
                (
                    id: "newer-resumed",
                    createdAt: base.addingTimeInterval(1),
                    activityAt: base.addingTimeInterval(110)
                ),
                (
                    id: "older-one-shot",
                    createdAt: base,
                    activityAt: base.addingTimeInterval(50)
                ),
            ],
            now: base.addingTimeInterval(110)
        )

        XCTAssertEqual(mapping["newer-resumed"], 202)
        XCTAssertEqual(mapping["older-one-shot"], 101)
        XCTAssertEqual(mapping.count, 2)
    }

    func testGrokProcessMatchingBreaksEqualScoresDeterministically() {
        let base = Date(timeIntervalSince1970: 40_000)
        let processes: [(pid: pid_t, startedAt: Date?)] = [
            (pid: 202, startedAt: base),
            (pid: 101, startedAt: base),
        ]
        let sessions: [(id: String, createdAt: Date?, activityAt: Date)] = [
            (id: "beta", createdAt: base, activityAt: base.addingTimeInterval(10)),
            (id: "alpha", createdAt: base, activityAt: base.addingTimeInterval(10)),
        ]

        let first = GrokDiscovery.matchGrokSessionsToProcesses(
            processes: processes,
            sessions: sessions,
            now: base.addingTimeInterval(10)
        )
        let second = GrokDiscovery.matchGrokSessionsToProcesses(
            processes: Array(processes.reversed()),
            sessions: Array(sessions.reversed()),
            now: base.addingTimeInterval(10)
        )

        XCTAssertEqual(first, ["alpha": 101, "beta": 202])
        XCTAssertEqual(second, first)
    }

    func testGrokNativeHookInstallIsNestedMatcherFreeAndIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cli = grokCLI(root: root)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))

        let data = try Data(contentsOf: root.appendingPathComponent("hooks/codeisland.json"))
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(rootJSON["hooks"] as? [String: Any])

        for event in cli.events.map(\.0) {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertNil(entries[0]["matcher"], "Grok rejects matcher on lifecycle hooks")
            let commands = try XCTUnwrap(entries[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue((commands[0]["command"] as? String)?.hasSuffix("--source grok") == true)
        }
    }

    func testGrokHookUninstallPreservesUserEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-hooks-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cli = grokCLI(root: root)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))
        let file = root.appendingPathComponent("hooks/codeisland.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [
            ["hooks": [["type": "command", "command": "/usr/bin/true"]]]
        ]
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: file)

        ConfigInstaller.uninstallHooks(cli: cli, fm: .default)

        let cleaned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let cleanedHooks = try XCTUnwrap(cleaned["hooks"] as? [String: Any])
        let stopEntries = try XCTUnwrap(cleanedHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopEntries.count, 1)
        let userCommands = try XCTUnwrap(stopEntries[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(userCommands[0]["command"] as? String, "/usr/bin/true")
    }

    // MARK: - Session store layouts (#331)

    func testBridgeOnlyForwardsAChatHistoryPathThatExists() {
        let expected = "/h/.grok/sessions/%2FUsers%2Ftest%2Fapp/sess-1/chat_history.jsonl"
        XCTAssertEqual(
            GrokSessionPaths.chatHistoryPath(grokHome: "/h/.grok", cwd: "/Users/test/app", sessionId: "sess-1"),
            expected
        )
        XCTAssertNil(GrokSessionPaths.existingChatHistoryPath(
            grokHome: "/h/.grok", cwd: "/Users/test/app", sessionId: "sess-1", fileExists: { _ in false }
        ))
        XCTAssertEqual(GrokSessionPaths.existingChatHistoryPath(
            grokHome: "/h/.grok", cwd: "/Users/test/app", sessionId: "sess-1", fileExists: { $0 == expected }
        ), expected)
        XCTAssertNil(GrokSessionPaths.chatHistoryPath(grokHome: "/h/.grok", cwd: "/Users/test/app", sessionId: "../x"))
        XCTAssertNil(GrokSessionPaths.chatHistoryPath(grokHome: "/h/.grok", cwd: "/Users/test/app", sessionId: ""))
    }

    func testSessionCreationTimeComesFromUUIDv7Only() throws {
        let created = try XCTUnwrap(GrokDiscovery.grokSessionCreationDate(
            fromSessionId: "01a05ffe-e470-76b1-b227-cedb9ae65aea"
        ))
        XCTAssertEqual(created.timeIntervalSince1970, 1_788_316_935.280, accuracy: 0.0005)
        XCTAssertNil(GrokDiscovery.grokSessionCreationDate(fromSessionId: "3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        XCTAssertNil(GrokDiscovery.grokSessionCreationDate(fromSessionId: "my-custom-session"))
    }

    /// #318's timeline: the resumed session was created 148 s before the TUI
    /// started and `/resume` touched it 57 s after. With only the index (no
    /// `created_at`), the UUIDv7 time keeps it on the resumed-session branch.
    func testUUIDCreationTimeScoresAResumedIndexOnlySession() throws {
        let processStart = Date(timeIntervalSince1970: 1_788_317_083) // 2026-09-02T02:44:43Z
        let createdAt = GrokDiscovery.grokSessionCreationDate(fromSessionId: "01a05ffe-e470-76b1-b227-cedb9ae65aea")

        XCTAssertNotNil(GrokDiscovery.grokSessionProcessMatchScore(
            createdAt: createdAt,
            activityAt: processStart.addingTimeInterval(57),
            processStart: processStart,
            now: processStart.addingTimeInterval(60)
        ))
        XCTAssertNil(GrokDiscovery.grokSessionProcessMatchScore(
            createdAt: createdAt,
            activityAt: processStart.addingTimeInterval(600),
            processStart: processStart,
            now: processStart.addingTimeInterval(600)
        ), "an old session touched long after launch is not claimed")
    }

    func testIndexIsReadLiveThroughTheWALWithoutBeingModified() throws {
        let root = try makeTemporaryDirectory("grok-index")
        defer { try? FileManager.default.removeItem(at: root) }
        let indexPath = root.appendingPathComponent("session_search.sqlite").path

        // Grok keeps its writer open; with checkpoints off the rows exist only
        // in the -wal file, which an `immutable` open would not see.
        let writer = try makeGrokSearchIndex(at: indexPath, rows: [
            ("01a0226f-1be5-7591-9031-cab500723788", "/work/app", 1_788_317_086),
            ("01a05ffe-e470-76b1-b227-cedb9ae65aea", "/work/app", 1_788_317_140),
            ("019fae00-39b9-7731-b244-9d056d07b684", "/work/other", 1_788_317_200),
        ])
        defer { sqlite3_close_v2(writer) }
        let walSize = try FileManager.default.attributesOfItem(atPath: indexPath + "-wal")[.size] as? NSNumber
        XCTAssertGreaterThan(walSize?.intValue ?? 0, 0, "fixture rows must live in the WAL")
        let mainFileBefore = try Data(contentsOf: URL(fileURLWithPath: indexPath))

        let rows = GrokDiscovery.grokIndexedSessions(databasePath: indexPath, cwd: "/work/app")

        XCTAssertEqual(rows.map(\.sessionId), [
            "01a05ffe-e470-76b1-b227-cedb9ae65aea",
            "01a0226f-1be5-7591-9031-cab500723788",
        ])
        XCTAssertEqual(rows.first?.updatedAt, Date(timeIntervalSince1970: 1_788_317_140))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: indexPath)), mainFileBefore)

        let missing = root.appendingPathComponent("absent.sqlite").path
        XCTAssertTrue(GrokDiscovery.grokIndexedSessions(databasePath: missing, cwd: "/work/app").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing), "a read-only open never creates the index")
    }

    func testIndexWithUnexpectedSchemaYieldsNoSessions() throws {
        let root = try makeTemporaryDirectory("grok-index-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let indexPath = root.appendingPathComponent("session_search.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(indexPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE session_docs (session_id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT);
            INSERT INTO session_docs VALUES ('01a05ffe-e470-76b1-b227-cedb9ae65aea', '/work/app', 'x');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)

        XCTAssertTrue(GrokDiscovery.grokIndexedSessions(databasePath: indexPath, cwd: "/work/app").isEmpty)
    }

    /// Both layouts on one machine: a session with a per-session directory
    /// keeps its transcript-backed candidate; a session only the index knows
    /// is added without a directory, so it never gets a transcript path.
    func testCandidatesMergeSessionDirectoriesWithTheSearchIndex() throws {
        let root = try makeTemporaryDirectory("grok-layouts")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent("sessions").path
        let cwd = "/work/app"
        let legacyId = "01a0226f-1be5-7591-9031-cab500723788"
        let indexOnlyId = "01a05ffe-e470-76b1-b227-cedb9ae65aea"

        let legacyDirectory = "\(sessionsRoot)/\(try XCTUnwrap(GrokDiscovery.grokEncodedCwd(cwd)))/\(legacyId)"
        try FileManager.default.createDirectory(atPath: legacyDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "info": ["id": legacyId, "cwd": cwd],
            "created_at": "2026-09-02T02:44:44Z",
            "updated_at": "2026-09-02T02:45:00Z",
            "current_model_id": "grok-4.6",
        ]).write(to: URL(fileURLWithPath: "\(legacyDirectory)/summary.json"))

        let writer = try makeGrokSearchIndex(at: "\(sessionsRoot)/session_search.sqlite", rows: [
            (legacyId, cwd, 1_788_317_100),
            (indexOnlyId, cwd, 1_788_317_140),
            ("019fae00-39b9-7731-b244-9d056d07b684", "/work/other", 1_788_317_200),
        ])
        defer { sqlite3_close_v2(writer) }

        let candidates = GrokDiscovery.grokSessionCandidates(cwd: cwd, sessionsRoot: sessionsRoot)
        let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.sessionId, $0) })

        XCTAssertEqual(Set(byId.keys), [legacyId, indexOnlyId])
        XCTAssertEqual(byId[legacyId]?.directory, legacyDirectory)
        XCTAssertEqual(byId[legacyId]?.model, "grok-4.6")
        XCTAssertEqual(byId[legacyId]?.createdAt, Date(timeIntervalSince1970: 1_788_317_084))
        XCTAssertNil(byId[indexOnlyId]?.directory)
        XCTAssertNil(byId[indexOnlyId]?.model)
        XCTAssertEqual(byId[indexOnlyId]?.activityAt, Date(timeIntervalSince1970: 1_788_317_140))
        XCTAssertEqual(
            byId[indexOnlyId]?.createdAt,
            GrokDiscovery.grokSessionCreationDate(fromSessionId: indexOnlyId)
        )

        let directoryOnly = GrokDiscovery.grokSessionCandidates(cwd: cwd, sessionsRoot: sessionsRoot, includeIndex: false)
        XCTAssertEqual(directoryOnly.map(\.sessionId), [legacyId])
    }

    func testDirectoryLayoutWorksWithoutAnIndex() throws {
        let root = try makeTemporaryDirectory("grok-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent("sessions").path
        let cwd = "/work/app"
        let sessionId = "01a0226f-1be5-7591-9031-cab500723788"
        let directory = "\(sessionsRoot)/\(try XCTUnwrap(GrokDiscovery.grokEncodedCwd(cwd)))/\(sessionId)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // No created_at: the UUIDv7 time fills in.
        try JSONSerialization.data(withJSONObject: [
            "info": ["id": sessionId, "cwd": cwd],
            "updated_at": "2026-09-02T02:45:00Z",
        ]).write(to: URL(fileURLWithPath: "\(directory)/summary.json"))

        let candidates = GrokDiscovery.grokSessionCandidates(cwd: cwd, sessionsRoot: sessionsRoot)

        XCTAssertEqual(candidates.map(\.sessionId), [sessionId])
        XCTAssertEqual(candidates.first?.directory, directory)
        XCTAssertEqual(candidates.first?.createdAt, GrokDiscovery.grokSessionCreationDate(fromSessionId: sessionId))
    }

    private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Grok 1.0.13's `session_search_schema_version = 4` index, left open in
    /// WAL mode with automatic checkpoints disabled. Caller closes the handle.
    private func makeGrokSearchIndex(
        at path: String,
        rows: [(sessionId: String, cwd: String, updatedAt: Int64)]
    ) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE session_docs (
                session_id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                content_hash TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE session_docs_fts USING fts5(
                title, content, content='session_docs', content_rowid='rowid'
            );
            CREATE TRIGGER session_docs_ai AFTER INSERT ON session_docs BEGIN
                INSERT INTO session_docs_fts(rowid, title, content)
                VALUES (new.rowid, new.title, new.content);
            END;
            INSERT INTO meta VALUES ('session_search_schema_version', '4');
            """, nil, nil, nil), SQLITE_OK)
        for row in rows {
            XCTAssertEqual(sqlite3_exec(db, """
                INSERT INTO session_docs VALUES
                ('\(row.sessionId)', '\(row.cwd)', \(row.updatedAt), 'title', 'hello', 'hash');
                """, nil, nil, nil), SQLITE_OK)
        }
        return db
    }

    private func grokCLI(root: URL) -> CLIConfig {
        CLIConfig(
            name: "Grok CLI",
            source: "grok",
            configPath: "hooks/codeisland.json",
            configKey: "hooks",
            format: .nested,
            events: GrokHookForwardingPolicy.managedHookEvents.map { ($0, 5, false) },
            rootOverride: { root.path }
        )
    }
}
