import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class CodexQuotaStoreTests: XCTestCase {
    func testRouterRefreshNeverCallsOfficialQuotaFetcher() throws {
        let root = try makeCodexHome(
            auth: #"{"auth_mode":"apikey","OPENAI_API_KEY":"redacted"}"#,
            config: "model_provider = \"api-router\"\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CodexQuotaStore(
            codexHomeProvider: { root.path },
            quotaFetcher: { _ in throw CodexQuotaFetchError.invalidResponse }
        )
        store.refresh()

        XCTAssertEqual(store.profile.accessKind, .apiRouter)
        XCTAssertEqual(store.profile.quotaCapability, .localUsageOnly)
        XCTAssertNil(store.error)
        XCTAssertNil(store.snapshot)
        store.stopAutoRefresh()
    }

    func testOfficialRefreshUsesInjectedQuotaFetcher() async throws {
        let root = try makeCodexHome(
            auth: #"{"auth_mode":"oauth","tokens":{"access_token":"redacted"}}"#,
            config: "model_provider = \"openai\"\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = CodexQuotaSnapshot(
            fiveHour: CodexQuotaWindow(usedPercent: 0.25, resetAt: nil),
            weekly: CodexQuotaWindow(usedPercent: 0.50, resetAt: nil),
            planType: "pro",
            fetchedAt: Date()
        )

        let store = CodexQuotaStore(
            codexHomeProvider: { root.path },
            quotaFetcher: { token in
                XCTAssertEqual(token, "redacted")
                return expected
            }
        )
        store.refresh()
        for _ in 0..<20 where store.snapshot == nil {
            await Task.yield()
        }

        XCTAssertEqual(store.profile.accessKind, .officialSubscription)
        XCTAssertEqual(store.snapshot, expected)
        XCTAssertNil(store.error)
        store.stopAutoRefresh()
    }

    private func makeCodexHome(auth: String, config: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-quota-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(auth.utf8).write(to: root.appendingPathComponent("auth.json"))
        try config.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return root
    }
}
