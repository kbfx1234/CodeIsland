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

    // MARK: - Thread lookup

    private func makeStateDatabase(rows: [(threadId: String, provider: String, cursor: String)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open((stateDir as NSString).appendingPathComponent("state.sqlite"), &db), SQLITE_OK)
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

    private func harness() -> HostHarness {
        HostHarness(
            kind: .t3Code,
            surface: .browser,
            serverPid: 400,
            stateDirectories: [stateDir],
            browserOrigin: "http://localhost:3773"
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
