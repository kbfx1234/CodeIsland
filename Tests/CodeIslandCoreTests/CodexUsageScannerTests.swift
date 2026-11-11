import XCTest
@testable import CodeIslandCore

final class CodexUsageScannerTests: XCTestCase {
    func testScansUsageBySourceAndSeparatesCachedInput() throws {
        let now = Date()
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        try write([
            sessionMeta(provider: "api-router"),
            turnContext(model: "gpt-5.6-sol"),
            usage(timestamp: now.addingTimeInterval(-3600), ordinal: 1,
                  input: 100, cached: 40, cacheWrite: 2, output: 20),
            usage(timestamp: now.addingTimeInterval(-3500), ordinal: 1,
                  input: 100, cached: 40, cacheWrite: 2, output: 20),
        ], to: root.appendingPathComponent("rollout-router.jsonl"))

        try write([
            sessionMeta(provider: "openai"),
            turnContext(model: "gpt-5.5"),
            usage(timestamp: now.addingTimeInterval(-1800), ordinal: 2,
                  input: 80, cached: 10, cacheWrite: 0, output: 30),
        ], to: root.appendingPathComponent("rollout-official.jsonl"))

        let snapshot = CodexUsageScanner.scan(
            codexHome: root.deletingLastPathComponent().path,
            now: now,
            fallbackSource: .apiRouter
        )
        let router = try XCTUnwrap(snapshot.usage(for: .apiRouter))
        let official = try XCTUnwrap(snapshot.usage(for: .officialSubscription))
        XCTAssertEqual(router.last5h.turnCount, 1)
        XCTAssertEqual(router.last5h.inputTokens, 60)
        XCTAssertEqual(router.last5h.cachedInputTokens, 40)
        XCTAssertEqual(router.last5h.cacheWriteTokens, 2)
        XCTAssertEqual(router.last5h.outputTokens, 20)
        XCTAssertEqual(official.last5h.totalTokens, 110)
        XCTAssertEqual(snapshot.last5h.turnCount, 2)
    }

    func testIncompleteTrailingLineIsConsumedOnceAfterCompletion() throws {
        let now = Date()
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("rollout-partial.jsonl")
        let complete = usage(timestamp: now.addingTimeInterval(-60), ordinal: 9,
                             input: 50, cached: 20, cacheWrite: 0, output: 5)
        try (sessionMeta(provider: "api-router") + "\n" + complete.dropLast(2))
            .write(to: file, atomically: true, encoding: .utf8)

        var cache = CodexUsageScanner.FileCache()
        let first = CodexUsageScanner.scan(
            codexHome: root.deletingLastPathComponent().path,
            now: now,
            fallbackSource: .apiRouter,
            cache: &cache
        )
        XCTAssertEqual(first.last5h.turnCount, 0)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("}}\n".utf8))
        try handle.close()

        let second = CodexUsageScanner.scan(
            codexHome: root.deletingLastPathComponent().path,
            now: now,
            fallbackSource: .apiRouter,
            cache: &cache
        )
        XCTAssertEqual(second.last5h.turnCount, 1)
        XCTAssertEqual(second.last5h.totalTokens, 55)

        let third = CodexUsageScanner.scan(
            codexHome: root.deletingLastPathComponent().path,
            now: now,
            fallbackSource: .apiRouter,
            cache: &cache
        )
        XCTAssertEqual(third.last5h.turnCount, 1)
    }

    func testMissingProviderUsesRuntimeFallback() throws {
        let now = Date()
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write([
            turnContext(model: "gpt-5.6-sol"),
            usage(timestamp: now.addingTimeInterval(-60), ordinal: 3,
                  input: 12, cached: 2, cacheWrite: 0, output: 3),
        ], to: root.appendingPathComponent("rollout-legacy.jsonl"))

        let snapshot = CodexUsageScanner.scan(
            codexHome: root.deletingLastPathComponent().path,
            now: now,
            fallbackSource: .apiKey
        )
        XCTAssertEqual(snapshot.usage(for: .apiKey)?.last5h.turnCount, 1)
    }

    func testCopiedRolloutWithSameSessionOrdinalCountsOnce() throws {
        let now = Date()
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let lines = [
            sessionMeta(provider: "api-router", id: "session-1"),
            turnContext(model: "gpt-5.6-sol"),
            usage(timestamp: now.addingTimeInterval(-60), ordinal: 4,
                  input: 40, cached: 10, cacheWrite: 0, output: 5),
        ]
        try write(lines, to: root.appendingPathComponent("rollout-a.jsonl"))
        try write(lines, to: root.appendingPathComponent("rollout-b.jsonl"))

        let snapshot = CodexUsageScanner.scan(
            codexHome: root.deletingLastPathComponent().path,
            now: now,
            fallbackSource: .apiRouter
        )
        XCTAssertEqual(snapshot.usage(for: .apiRouter)?.last5h.turnCount, 1)
        XCTAssertEqual(snapshot.usage(for: .apiRouter)?.last5h.totalTokens, 45)
    }

    private func makeSessionsRoot() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return sessions
    }

    private func write(_ lines: [String], to file: URL) throws {
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }

    private func sessionMeta(provider: String, id: String? = nil) -> String {
        if let id {
            return "{\"type\":\"session_meta\",\"payload\":{\"model_provider\":\"\(provider)\",\"id\":\"\(id)\"}}"
        }
        return "{\"type\":\"session_meta\",\"payload\":{\"model_provider\":\"\(provider)\"}}"
    }

    private func turnContext(model: String) -> String {
        #"{"type":"turn_context","payload":{"model":"\#(model)"}}"#
    }

    private func usage(
        timestamp: Date,
        ordinal: Int,
        input: Int,
        cached: Int,
        cacheWrite: Int,
        output: Int
    ) -> String {
        let stamp = ISO8601DateFormatter().string(from: timestamp)
        return #"{"timestamp":"\#(stamp)","type":"event_msg","ordinal":\#(ordinal),"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output)}}}}"#
    }
}
