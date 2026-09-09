import XCTest
@testable import CodeIslandCore

final class KiroUsageScannerTests: XCTestCase {
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
    }

    func testFormatCreditsIsCompact() {
        XCTAssertEqual(KiroUsageScanner.formatCredits(2.5), "2.5")
        XCTAssertEqual(KiroUsageScanner.formatCredits(1000), "1K")
    }
}
