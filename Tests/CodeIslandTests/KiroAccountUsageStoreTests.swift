import XCTest
@testable import CodeIsland
import CodeIslandCore
import SQLite3

@MainActor
final class KiroAccountUsageStoreTests: XCTestCase {
    private func makeDatabase(with value: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiro-state-\(UUID().uuidString).vscdb").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB);", nil, nil, nil), SQLITE_OK)
        let sql = "INSERT INTO ItemTable(key, value) VALUES(?, ?);"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { if let statement { sqlite3_finalize(statement) } }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = "kiro.kiroAgent".withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = value.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        return path
    }

    func testRefreshParsesInjectedReadOnlyCache() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "kiro.resourceNotifications.usageState": [
                "usageBreakdowns": [[
                    "type": "CREDIT",
                    "currentUsage": 5316.10,
                    "usageLimit": 5000,
                    "resetDate": "2026-10-01T00:00:00Z",
                ]],
                "timestamp": 1_789_551_790_802,
            ],
        ])
        let store = KiroAccountUsageStore(dataReader: { data })
        store.refresh()
        for _ in 0..<1000 {
            if store.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.snapshot)
        XCTAssertEqual(store.snapshot?.currentUsage ?? 0, 5316.10, accuracy: 0.0001)
        XCTAssertEqual(store.snapshot?.usageLimit ?? 0, 5000, accuracy: 0.0001)
        XCTAssertNil(store.error)
    }

    func testRefreshDoesNotKeepStaleSnapshotWhenCacheIsUnavailable() async throws {
        let store = KiroAccountUsageStore(dataReader: { nil })
        store.refresh()
        for _ in 0..<1000 {
            if !store.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.error, "Kiro account usage cache unavailable")
    }

    func testRefreshReadsTheKiroStateDatabaseReadOnly() async throws {
        let value = #"{"kiro.resourceNotifications.usageState":{"usageBreakdowns":[{"type":"CREDIT","currentUsage":5415.95,"usageLimit":5000,"resetDate":"2026-10-01T00:00:00Z"}]}}"#
        let path = try makeDatabase(with: value)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = KiroAccountUsageStore(databasePathProvider: { path })
        store.refresh()
        for _ in 0..<1000 {
            if store.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.snapshot?.currentUsage ?? 0, 5415.95, accuracy: 0.0001)
        XCTAssertNil(store.error)
    }
}
