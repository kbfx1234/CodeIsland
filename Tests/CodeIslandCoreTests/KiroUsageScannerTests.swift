import XCTest
@testable import CodeIslandCore

final class KiroUsageScannerTests: XCTestCase {
    private func cliData(id: String, at date: Date, credits: Double) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: [
            "session_id": id,
            "session_state": ["conversation_metadata": ["user_turn_metadatas": [[
                "end_timestamp": formatter.string(from: date),
                "metering_usage": [
                    ["unit": "credit", "value": credits],
                    ["unit": "tokens", "value": 999],
                ],
            ]]]],
        ])
    }

    private func line(id: String, at date: Date, usage: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date)
        return "{\"id\":\"\(id)\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"usage_summary\",\"promptTurnSummaries\":[{\"unit\":\"credit\",\"usage\":\(usage)}]}}"
    }

    func testParseUsageSummaryExtractsOnlyCreditUnits() {
        let now = Date()
        let parsed = KiroUsageScanner.parseUsageSummary(line(id: "u1", at: now, usage: 2.5))
        XCTAssertEqual(parsed?.id, "u1")
        XCTAssertEqual(parsed?.credits, 2.5)
    }

    func testScanAggregatesRecentAndTodayCredits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let messages = root.appendingPathComponent("sessions/a/messages.jsonl")
        try FileManager.default.createDirectory(at: messages.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let content = [
            line(id: "recent", at: now.addingTimeInterval(-3600), usage: 1.25),
            line(id: "morning", at: now.addingTimeInterval(-8 * 3600), usage: 3.5),
            line(id: "old", at: now.addingTimeInterval(-30 * 3600), usage: 99),
        ].joined(separator: "\n")
        try content.write(to: messages, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = KiroUsageScanner.scan(kiroHome: root.path, now: now)
        XCTAssertEqual(snapshot.last5h.credits, 1.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.today.credits, 4.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.last5h.turnCount, 1)
        XCTAssertEqual(snapshot.today.turnCount, 2)
        XCTAssertEqual(snapshot.scannedFiles, 1)
        XCTAssertNil(snapshot.notice)
    }

    func testIncrementalCacheKeepsExistingRowsAndDeduplicatesAppends() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let messages = root.appendingPathComponent("sessions/a/messages.jsonl")
        try FileManager.default.createDirectory(at: messages.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let first = line(id: "first", at: now.addingTimeInterval(-60), usage: 1.0)
        let duplicate = line(id: "first", at: now.addingTimeInterval(-30), usage: 9.0)
        let second = line(id: "second", at: now.addingTimeInterval(-10), usage: 2.0)
        try first.write(to: messages, atomically: true, encoding: .utf8)

        var cache = KiroUsageScanner.FileCache()
        let initial = KiroUsageScanner.scan(kiroHome: root.path, now: now, cache: &cache)
        XCTAssertEqual(initial.today.credits, 1.0, accuracy: 0.0001)

        let handle = try FileHandle(forWritingTo: messages)
        handle.seekToEndOfFile()
        handle.write(Data(("\n" + duplicate + "\n" + second).utf8))
        try handle.close()

        let updated = KiroUsageScanner.scan(kiroHome: root.path, now: now, cache: &cache)
        XCTAssertEqual(updated.today.credits, 3.0, accuracy: 0.0001)
        XCTAssertEqual(updated.today.turnCount, 2)
    }

    func testDuplicateUsageIDAcrossSessionFilesCountsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("sessions/a/messages.jsonl")
        let second = root.appendingPathComponent("sessions/b/messages.jsonl")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try line(id: "shared", at: now.addingTimeInterval(-30), usage: 4)
            .write(to: first, atomically: true, encoding: .utf8)
        try line(id: "shared", at: now.addingTimeInterval(-20), usage: 4)
            .write(to: second, atomically: true, encoding: .utf8)

        let snapshot = KiroUsageScanner.scan(kiroHome: root.path, now: now)
        XCTAssertEqual(snapshot.today.credits, 4, accuracy: 0.0001)
        XCTAssertEqual(snapshot.today.turnCount, 1)
    }

    func testFormatCreditsIsCompact() {
        XCTAssertEqual(KiroUsageScanner.formatCredits(2.5), "2.5")
        XCTAssertEqual(KiroUsageScanner.formatCredits(1000), "1K")
    }

    func testCLIAndIDEUsageAreCombinedWithoutCountingTranscriptText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cli = root.appendingPathComponent("sessions/cli/a.json")
        let ide = root.appendingPathComponent("sessions/ide/messages.jsonl")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ide.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try cliData(id: "cli-session", at: now.addingTimeInterval(-10), credits: 10.09).write(to: cli)
        try line(id: "ide-usage", at: now.addingTimeInterval(-10), usage: 0.49)
            .write(to: ide, atomically: true, encoding: .utf8)
        try line(id: "transcript-duplicate", at: now.addingTimeInterval(-10), usage: 99)
            .write(to: cli.deletingPathExtension().appendingPathExtension("jsonl"), atomically: true, encoding: .utf8)
        let snapshot = KiroUsageScanner.scan(kiroHome: root.path, now: now)
        XCTAssertEqual(snapshot.last5h.credits, 10.58, accuracy: 0.0001)
        XCTAssertEqual(snapshot.last5h.turnCount, 2)
        XCTAssertEqual(snapshot.scannedCLIFiles, 1)
        XCTAssertEqual(snapshot.scannedFiles, 2)
    }

    func testEmptyKiroHomeReportsAUsefulNotice() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = KiroUsageScanner.scan(kiroHome: root.path, now: Date())
        XCTAssertEqual(snapshot.scannedFiles, 0)
        XCTAssertEqual(snapshot.notice, "No Kiro local usage records yet")
    }

    func testCLICopiedSessionMetadataCountsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cli = root.appendingPathComponent("sessions/cli/a.json")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let data = try cliData(id: "shared-session", at: now.addingTimeInterval(-10), credits: 10.09)
        try data.write(to: cli)
        try data.write(to: cli.deletingLastPathComponent().appendingPathComponent("copy.json"))
        let snapshot = KiroUsageScanner.scan(kiroHome: root.path, now: now)
        XCTAssertEqual(snapshot.last5h.credits, 10.09, accuracy: 0.0001)
        XCTAssertEqual(snapshot.last5h.turnCount, 1)
    }

    func testCLISameSizeRewriteReplacesCachedUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cli = root.appendingPathComponent("sessions/cli/a.json")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let first = try cliData(id: "session", at: now.addingTimeInterval(-10), credits: 1)
        let second = try cliData(id: "session", at: now.addingTimeInterval(-10), credits: 2)
        XCTAssertEqual(first.count, second.count)
        try first.write(to: cli)
        var cache = KiroUsageScanner.FileCache()
        XCTAssertEqual(KiroUsageScanner.scan(kiroHome: root.path, now: now, cache: &cache).last5h.credits, 1)
        try second.write(to: cli)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: cli.path)
        XCTAssertEqual(KiroUsageScanner.scan(kiroHome: root.path, now: now, cache: &cache).last5h.credits, 2)
    }

    func testMalformedCLIRecordReportsUnreadableWithoutChangingIDEUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cli = root.appendingPathComponent("sessions/cli/a.json")
        let ide = root.appendingPathComponent("sessions/ide/messages.jsonl")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ide.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try "{partial".write(to: cli, atomically: true, encoding: .utf8)
        try line(id: "ide", at: now.addingTimeInterval(-10), usage: 0.49)
            .write(to: ide, atomically: true, encoding: .utf8)
        let snapshot = KiroUsageScanner.scan(kiroHome: root.path, now: now)
        XCTAssertEqual(snapshot.last5h.credits, 0.49, accuracy: 0.0001)
        XCTAssertEqual(snapshot.unreadableFiles, 1)
        XCTAssertEqual(snapshot.scannedCLIFiles, 0)
    }

    func testCLIBrokenRewriteDoesNotRetainOldCredits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cli = root.appendingPathComponent("sessions/cli/a.json")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try cliData(id: "session", at: now.addingTimeInterval(-10), credits: 10).write(to: cli)
        var cache = KiroUsageScanner.FileCache()
        XCTAssertEqual(KiroUsageScanner.scan(kiroHome: root.path, now: now, cache: &cache).last5h.credits, 10)
        try "{partial".write(to: cli, atomically: true, encoding: .utf8)
        let broken = KiroUsageScanner.scan(kiroHome: root.path, now: now, cache: &cache)
        XCTAssertEqual(broken.last5h.credits, 0)
        XCTAssertEqual(broken.unreadableFiles, 1)
        try cliData(id: "session", at: now.addingTimeInterval(-10), credits: 12).write(to: cli)
        XCTAssertEqual(KiroUsageScanner.scan(kiroHome: root.path, now: now, cache: &cache).last5h.credits, 12)
    }
}
