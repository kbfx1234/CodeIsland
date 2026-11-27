import Combine
import Foundation
import SQLite3
import CodeIslandCore

@MainActor
final class KiroAccountUsageStore: ObservableObject {
    static let shared = KiroAccountUsageStore(liveReader: { KiroAccountUsageClient.fetch() })

    typealias DataReader = @Sendable () -> Data?
    typealias LiveReader = @Sendable () -> KiroAccountUsageSnapshot?

    @Published private(set) var snapshot: KiroAccountUsageSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isUsingCache = false
    @Published private(set) var lastAttempt: Date?

    private let dataReader: DataReader
    private let liveReader: LiveReader
    private var refreshTask: Task<Void, Never>?

    init(
        databasePathProvider: @escaping @Sendable () -> String = {
            NSHomeDirectory() + "/Library/Application Support/Kiro/User/globalStorage/state.vscdb"
        },
        dataReader: DataReader? = nil,
        liveReader: @escaping LiveReader = { nil }
    ) {
        self.liveReader = liveReader
        if let dataReader {
            self.dataReader = dataReader
        } else {
            self.dataReader = { Self.readAgentJSON(path: databasePathProvider()) }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func refreshOnExpansion(now: Date = Date()) {
        // Hovering back across the notch may open the list again right away.
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 15 { return }
        refresh()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        let reader = dataReader
        let liveReader = liveReader
        lastAttempt = Date()
        isLoading = true
        refreshTask = Task { [weak self] in
            let result: (KiroAccountUsageSnapshot?, String?, Bool) = await Task.detached(priority: .utility) {
                if let live = liveReader() { return (live, nil, false) }
                guard let data = reader() else { return (nil, "Kiro account usage cache unavailable", false) }
                guard let snapshot = KiroAccountUsageParser.parse(data: data) else {
                    return (nil, "Kiro account usage cache format not recognized", false)
                }
                return (snapshot, nil, true)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.snapshot = result.0
            self.error = result.1
            self.isUsingCache = result.2
            self.isLoading = false
            self.refreshTask = nil
        }
    }

    private nonisolated static func readAgentJSON(path: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        defer { sqlite3_close_v2(db) }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = "kiro.kiroAgent".withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: bytes, count: length)
    }
}
