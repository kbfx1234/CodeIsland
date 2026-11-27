import XCTest
import SQLite3
@testable import CodeIsland
@testable import CodeIslandCore

/// #321 — process/state side of T3 Code support: the ancestry probe against
/// real processes, and the thread lookup against a state.sqlite shaped like
/// T3's (`provider_session_runtime`, migrations 004 + 027).
final class T3CodeHarnessSupportTests: XCTestCase {
    private var stateDir: String!

    override func setUpWithError() throws {
        stateDir = NSTemporaryDirectory() + "t3-harness-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    // MARK: - Probe

    func testProbeOfTheTestRunnerFindsNoHarness() {
        let result = HostHarnessSupport.probe(cliPid: getpid())
        XCTAssertTrue(result.conclusive, "a live process can be walked")
        XCTAssertNil(result.harness)
    }

    func testProbeOfAnExitedProcessIsInconclusive() {
        // pid_max on macOS is 99998; this pid cannot exist.
        let result = HostHarnessSupport.probe(cliPid: 99_999_999)
        XCTAssertFalse(result.conclusive, "must be retried later, not cached as 'no harness'")
        XCTAssertNil(result.harness)
    }

    @MainActor
    func testQuietKiroTurnStaysActiveUntilStop() async throws {
        let appState = AppState()
        let t3Id = "t3-kiro"
        let rexId = "rex-kiro"
        appState.storeReaders.kiroTurnIsActive = { $0 == t3Id || $0 == rexId }
        func send(_ name: String, sessionId: String) throws {
            appState.handleEvent(try XCTUnwrap(HookEvent(json: [
                "hook_event_name": name,
                "session_id": sessionId,
                "_source": "kiro",
                "_ppid": getpid(),
                "cwd": "/tmp",
                "prompt": "Run the build",
            ])))
        }

        try send("UserPromptSubmit", sessionId: t3Id)
        try send("UserPromptSubmit", sessionId: rexId)
        try send("UserPromptSubmit", sessionId: "terminal-kiro")
        appState.sessions[t3Id]?.hostHarness = harness()
        let eightMinutesAgo = Date().addingTimeInterval(-480)
        appState.sessions[t3Id]?.lastActivity = eightMinutesAgo
        appState.sessions[rexId]?.lastActivity = eightMinutesAgo
        appState.sessions["terminal-kiro"]?.lastActivity = eightMinutesAgo

        appState.cleanupIdleSessions()
        await waitUntil { appState.kiroTurnReadsInFlight.isEmpty }

        XCTAssertEqual(appState.sessions[t3Id].map(SessionCardStatus.init), .thinking)
        XCTAssertEqual(appState.sessions[rexId].map(SessionCardStatus.init), .thinking)
        XCTAssertEqual(appState.sessions["terminal-kiro"].map(SessionCardStatus.init), .done)

        try send("Stop", sessionId: t3Id)
        try send("Stop", sessionId: rexId)
        XCTAssertEqual(appState.sessions[t3Id].map(SessionCardStatus.init), .done)
        XCTAssertEqual(appState.sessions[rexId].map(SessionCardStatus.init), .done)
    }

    // MARK: - Thread lookup

    private func makeStateDatabase(
        rows: [(threadId: String, provider: String, cursor: String)], file: String = "state.sqlite"
    ) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open((stateDir as NSString).appendingPathComponent(file), &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE provider_session_runtime (
              thread_id TEXT PRIMARY KEY,
              provider_name TEXT NOT NULL,
              adapter_key TEXT NOT NULL,
              runtime_mode TEXT NOT NULL DEFAULT 'full-access',
              status TEXT NOT NULL,
              last_seen_at TEXT NOT NULL,
              resume_cursor_json TEXT,
              runtime_payload_json TEXT,
              provider_instance_id TEXT
            );
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for row in rows {
            let insert = """
                INSERT INTO provider_session_runtime
                  (thread_id, provider_name, adapter_key, status, last_seen_at, resume_cursor_json)
                VALUES ('\(row.threadId)', '\(row.provider)', '\(row.provider)', 'running', 'now', '\(row.cursor)');
                """
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
    }

    private func makeProjection(rows: [(threadId: String, provider: String, nativeId: String)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open((stateDir as NSString).appendingPathComponent("statev2.sqlite"), &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE orchestration_v2_projection_provider_threads (
              provider_thread_id TEXT PRIMARY KEY,
              thread_id TEXT,
              provider TEXT NOT NULL,
              provider_session_id TEXT,
              payload_json TEXT NOT NULL
            );
            CREATE TABLE orchestration_v2_projection_threads (
              thread_id TEXT PRIMARY KEY,
              deleted_at TEXT
            );
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let insert = """
                INSERT OR IGNORE INTO orchestration_v2_projection_threads VALUES ('\(row.threadId)', NULL);
                INSERT INTO orchestration_v2_projection_provider_threads
                VALUES ('provider-thread-\(index)', '\(row.threadId)', '\(row.provider)', 'provider-session-\(index)',
                    json_object('nativeThreadRef', json_object('nativeId', '\(row.nativeId)')));
                """
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
    }

    private func makeRuntime(pid: Int = 400) throws {
        try "env-1\n".write(toFile: stateDir + "/environment-id", atomically: true, encoding: .utf8)
        try #"{"pid":\#(pid),"port":3773}"#.write(toFile: stateDir + "/server-runtime.json", atomically: true, encoding: .utf8)
    }

    private func harness(bundleId: String? = nil) -> HostHarness {
        HostHarness(
            kind: .t3Code,
            surface: bundleId.map { .desktopApp(bundleId: $0) } ?? .browser,
            serverPid: 400,
            stateDirectories: [stateDir],
            browserOrigin: bundleId == nil ? "http://localhost:3773" : nil
        )
    }

    private func session(source: String) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.source = source
        return snapshot
    }

    func testClaudeSessionOpensItsT3Thread() throws {
        try "env-1\n".write(toFile: (stateDir as NSString).appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        try makeStateDatabase(rows: [
            ("thread-a", "claudeAgent", #"{"threadId":"thread-a","resume":"11111111-2222-3333-4444-555555555555","turnCount":2}"#),
            ("thread-b", "codex", #"{"threadId":"019a-codex-thread"}"#),
            ("thread-c", "opencode", #"{"schemaVersion":1,"sessionId":"ses_abc"}"#),
        ])

        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "11111111-2222-3333-4444-555555555555", session: session(source: "claude"))?.absoluteString,
            "http://localhost:3773/env-1/thread-a"
        )
        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "019a-codex-thread", session: session(source: "codex"))?.absoluteString,
            "http://localhost:3773/env-1/thread-b"
        )
        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "opencode-ses_abc", session: session(source: "opencode"))?.absoluteString,
            "http://localhost:3773/env-1/thread-c"
        )
    }

    func testV2OpensProviderThreadInEitherDesktopInstanceAndBrowser() throws {
        try makeRuntime()
        try makeProjection(rows: [
            ("kiro-thread", "kiro", "sess_abc"),
            ("kiro-thread", "kiro", "sess_abc"),
            ("codex-thread", "codex", "native-codex"),
            ("claude-thread", "claudeAgent", "native-claude"),
            ("other-thread", "codex", "sess_abc"),
        ])
        var kiro = session(source: "kiro")
        kiro.providerSessionId = "sess_abc"
        let custom = harness(bundleId: "com.kbfx1234.t3code.custom")
        let standard = harness(bundleId: "com.t3tools.t3code")
        XCTAssertEqual(
            HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "local-card-id", session: kiro)?.absoluteString,
            "t3code-custom://threads/env-1/kiro-thread"
        )
        XCTAssertEqual(
            HostHarnessSupport.t3DesktopURL(harness: standard, sessionId: "native-codex", session: session(source: "codex"))?.absoluteString,
            "t3code://threads/env-1/codex-thread"
        )
        XCTAssertEqual(
            HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "native-claude", session: session(source: "claude"))?.absoluteString,
            "t3code-custom://threads/env-1/claude-thread"
        )
        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "sess_abc", session: kiro)?.absoluteString,
            "http://localhost:3773/env-1/kiro-thread"
        )
    }

    func testDesktopSkipsStateOwnedByAnotherProcess() throws {
        try makeRuntime(pid: 401)
        try makeProjection(rows: [("kiro-thread", "kiro", "sess_abc")])
        let custom = harness(bundleId: "com.kbfx1234.t3code.custom")
        XCTAssertNil(HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "sess_abc", session: session(source: "kiro")))
    }

    func testV2RefusesMissingAndConflictingIdentities() throws {
        try makeRuntime()
        try makeProjection(rows: [
            ("first-thread", "kiro", "sess_dup"),
            ("second-thread", "kiro", "sess_dup"),
            ("first-thread", "kiro", "sess_first"),
            ("second-thread", "kiro", "sess_second"),
        ])
        try makeStateDatabase(rows: [
            ("first-thread", "kiro", #"{"sessionId":"sess_dup"}"#),
        ], file: "statev2.sqlite")
        let custom = harness(bundleId: "com.kbfx1234.t3code.custom")
        let kiro = session(source: "kiro")
        XCTAssertNil(HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "sess_dup", session: kiro))
        XCTAssertNil(HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "sess_missing", session: kiro))
        var conflicting = kiro
        conflicting.providerSessionId = "sess_second"
        XCTAssertNil(HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "sess_first", session: conflicting))
    }

    func testDesktopCanReadLegacyT3State() throws {
        try makeRuntime()
        try makeStateDatabase(rows: [
            ("codex-thread", "codex", #"{"threadId":"shared-id"}"#),
            ("claude-thread", "claudeAgent", #"{"resume":"shared-id"}"#),
        ])
        let standard = harness(bundleId: "com.t3tools.t3code")
        XCTAssertEqual(
            HostHarnessSupport.t3DesktopURL(harness: standard, sessionId: "shared-id", session: session(source: "claude"))?.absoluteString,
            "t3code://threads/env-1/claude-thread"
        )
    }

    func testV2OpensAnImportedThreadThroughItsLegacyResumeCursor() throws {
        try makeRuntime()
        try makeProjection(rows: [("import:claude:thread", "claudeAgent", "placeholder")])
        try makeStateDatabase(rows: [
            ("import:claude:thread", "claudeAgent", #"{"resume":"legacy-claude"}"#),
            ("missing-thread", "claudeAgent", #"{"resume":"legacy-missing"}"#),
        ], file: "statev2.sqlite")
        let custom = harness(bundleId: "com.kbfx1234.t3code.custom")
        let claude = session(source: "claude")
        XCTAssertEqual(
            HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "legacy-claude", session: claude)?.absoluteString,
            "t3code-custom://threads/env-1/import%3Aclaude%3Athread"
        )
        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "legacy-claude", session: claude)?.absoluteString,
            "http://localhost:3773/env-1/import%3Aclaude%3Athread"
        )
        XCTAssertNil(HostHarnessSupport.t3DesktopURL(harness: custom, sessionId: "legacy-missing", session: claude))
    }

    func testUnknownOrAmbiguousSessionFallsBackToT3Root() throws {
        try "env-1".write(toFile: (stateDir as NSString).appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        try makeStateDatabase(rows: [
            ("thread-a", "claudeAgent", #"{"resume":"dup"}"#),
            ("thread-b", "claudeAgent", #"{"resume":"dup"}"#),
        ])
        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "dup", session: session(source: "claude"))?.absoluteString,
            "http://localhost:3773/",
            "two threads claim the id — refuse to guess"
        )
        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "typed-in-t3-terminal", session: session(source: "claude"))?.absoluteString,
            "http://localhost:3773/"
        )
    }

    func testMissingStateDegradesToRootInsteadOfFailing() {
        // No environment-id, no database (schema drift / different base dir).
        XCTAssertEqual(
            HostHarnessSupport.t3BrowserURL(harness: harness(), sessionId: "x", session: session(source: "claude"))?.absoluteString,
            "http://localhost:3773/"
        )
        var unverified = harness()
        unverified.browserOrigin = nil
        XCTAssertNil(HostHarnessSupport.t3BrowserURL(harness: unverified, sessionId: "x", session: session(source: "claude")))
    }
}
