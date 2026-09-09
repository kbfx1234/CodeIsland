import Foundation

public struct KiroUsageTotals: Equatable, Sendable {
    public var credits: Double = 0
    public var turnCount: Int = 0
    public var isEmpty: Bool { turnCount == 0 }

    public init() {}

    mutating func add(credits: Double) {
        self.credits += credits
        turnCount += 1
    }
}

/// Aggregates credit usage from Kiro's local session records. This is local
/// activity, not the account quota returned by Kiro's interactive `/usage`.
public enum KiroUsageScanner {
    public static let sparklineHours = 12

    public struct Snapshot: Equatable, Sendable {
        public let last5h: KiroUsageTotals
        public let today: KiroUsageTotals
        public let hourlyCredits: [Double]
        public let scannedAt: Date

        public init(last5h: KiroUsageTotals, today: KiroUsageTotals, hourlyCredits: [Double], scannedAt: Date) {
            self.last5h = last5h
            self.today = today
            self.hourlyCredits = hourlyCredits
            self.scannedAt = scannedAt
        }
    }

    public static func scan(
        kiroHome: String = NSHomeDirectory() + "/.kiro",
        now: Date = Date()
    ) -> Snapshot {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(sparklineHours) * 3600)
        let cutoff = min(fiveHoursAgo, midnight, sparklineStart)
        var last5h = KiroUsageTotals()
        var today = KiroUsageTotals()
        var hourly = [Double](repeating: 0, count: sparklineHours)

        let sessions = URL(fileURLWithPath: kiroHome).appendingPathComponent("sessions")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = files?.nextObject() as? URL {
            guard url.lastPathComponent == "messages.jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            aggregate(text: text, now: now, fiveHoursAgo: fiveHoursAgo,
                      midnight: midnight, into: &last5h, today: &today, hourly: &hourly)
        }
        return Snapshot(last5h: last5h, today: today, hourlyCredits: hourly, scannedAt: now)
    }

    static func parseUsageSummary(_ line: String) -> (id: String, timestamp: Date, credits: Double)? {
        guard line.contains("\"usage_summary\""), line.contains("\"credit\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String,
              let rawTimestamp = root["timestamp"] as? String,
              let timestamp = parseISO8601(rawTimestamp),
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "usage_summary",
              let summaries = payload["promptTurnSummaries"] as? [[String: Any]] else { return nil }
        let credits = summaries.reduce(0.0) { total, item in
            guard item["unit"] as? String == "credit" else { return total }
            return total + ((item["usage"] as? NSNumber)?.doubleValue ?? 0)
        }
        guard credits.isFinite, credits >= 0 else { return nil }
        return (id, timestamp, credits)
    }

    private static func aggregate(
        text: String, now: Date, fiveHoursAgo: Date, midnight: Date,
        into last5h: inout KiroUsageTotals, today: inout KiroUsageTotals,
        hourly: inout [Double]
    ) {
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard let item = parseUsageSummary(String(line)), seen.insert(item.id).inserted,
                  item.timestamp <= now else { continue }
            if item.timestamp >= fiveHoursAgo { last5h.add(credits: item.credits) }
            if item.timestamp >= midnight { today.add(credits: item.credits) }
            let hoursAgo = Int(now.timeIntervalSince(item.timestamp) / 3600)
            if hoursAgo >= 0, hoursAgo < sparklineHours {
                hourly[sparklineHours - 1 - hoursAgo] += item.credits
            }
        }
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func parseISO8601(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }

    public static func formatCredits(_ credits: Double) -> String {
        guard credits.isFinite else { return "0" }
        if credits >= 1000 {
            return String(format: "%.1fK", credits / 1000)
                .replacingOccurrences(of: ".0K", with: "K")
        }
        return String(format: credits >= 100 ? "%.0f" : "%.2f", credits)
            .replacingOccurrences(of: #"\.00$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\.\d)0$"#, with: "$1", options: .regularExpression)
    }
}
