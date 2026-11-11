import CryptoKit
import SQLite3
import XCTest
@testable import CodeIsland

/// Codex keeps `~/.codex/state_5.sqlite` in WAL mode and removes the -wal and
/// -shm files whenever its last connection closes, as when Codex Desktop sits
/// idle. A read-only connection can't create them, so every statement on such
/// a database failed with SQLITE_CANTOPEN (14). That happened outside any
/// sandbox too (`sqlite3 -readonly` on a copy fails the same way), and with it
/// went Desktop thread discovery, spawn edges, the thread → rollout lookups
/// and the end-of-turn check. Reads must also leave the database exactly as
/// they found it: no -wal/-shm created, no byte changed.
final class SQLiteReaderClosedWALTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("closed-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A WAL-mode state database whose writer has closed it: everything
    /// checkpointed into the file, no -wal or -shm beside it.
    private func makeClosedWALStateDatabase(rolloutPath: String, updatedAt: Int64) throws -> String {
        let path = dir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                model TEXT,
                archived INTEGER NOT NULL,
                has_user_event INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            INSERT INTO threads VALUES (
                'idle-desktop-thread', '\(rolloutPath)', '/repo', \(updatedAt), 'gpt-test', 0, 1, 'vscode'
            );
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)
        // macOS's SQLite may keep the WAL files after the last close; Codex's
        // doesn't.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        let header = try XCTUnwrap(FileManager.default.contents(atPath: path))
        XCTAssertEqual(Array(header[18...19]), [2, 2], "the database is in WAL mode")
        return path
    }

    private func fingerprint(_ path: String) throws -> String {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertUntouched(_ path: String, fingerprint before: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try fingerprint(path), before, "no byte of the database changed", file: file, line: line)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path + suffix),
                "reading created \(suffix)", file: file, line: line
            )
        }
    }

    func testAClosedWALDatabaseIsReadWithoutTouchingIt() throws {
        let path = try makeClosedWALStateDatabase(rolloutPath: "/nowhere.jsonl", updatedAt: 1)
        let before = try fingerprint(path)

        let count: Int? = SQLiteReader.withSQLiteDatabase(at: path) { db in
            guard let statement = SQLiteReader.prepareSQLiteStatement(db: db, sql: "SELECT count(*) FROM threads;") else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(statement, 0))
        }

        XCTAssertEqual(count, 1)
        try assertUntouched(path, fingerprint: before)
    }

    func testAnIdleDesktopThreadIsFoundInAClosedWALStateDatabase() throws {
        let rollout = dir.appendingPathComponent("rollout.jsonl")
        try (#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)
        let now = Date()
        let path = try makeClosedWALStateDatabase(rolloutPath: rollout.path, updatedAt: Int64(now.timeIntervalSince1970))
        let before = try fingerprint(path)

        let records = CodexDiscovery.recentCodexDesktopThreadRecords(statePath: path, now: now)

        XCTAssertEqual(records.map(\.sessionId), ["idle-desktop-thread"])
        try assertUntouched(path, fingerprint: before)
    }

    func testAnOpenWALDatabaseIsStillReadNormally() throws {
        let path = try makeClosedWALStateDatabase(rolloutPath: "/nowhere.jsonl", updatedAt: 1)
        // A writer holding it open, as while Codex runs.
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close_v2(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO threads VALUES ('new', '/x', '/repo', 2, NULL, 0, 1, 'cli');", nil, nil, nil), SQLITE_OK)

        let count: Int? = SQLiteReader.withSQLiteDatabase(at: path) { db in
            guard let statement = SQLiteReader.prepareSQLiteStatement(db: db, sql: "SELECT count(*) FROM threads;") else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(statement, 0))
        }

        XCTAssertEqual(count, 2, "the reader sees the writer's committed row in the WAL")
    }

    func testAMissingDatabaseIsStillNothing() {
        let path = dir.appendingPathComponent("absent.sqlite").path
        let opened: Bool? = SQLiteReader.withSQLiteDatabase(at: path) { _ in true }
        XCTAssertNil(opened)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "nothing is created")
    }
}
