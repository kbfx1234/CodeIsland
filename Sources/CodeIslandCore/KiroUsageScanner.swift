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

    fileprivate struct CachedUsage: Sendable {
        let id: String
        let timestamp: Date
        let credits: Double
    }

    public struct Snapshot: Equatable, Sendable {
        public let last5h: KiroUsageTotals
        public let today: KiroUsageTotals
        public let hourlyCredits: [Double]
        public let scannedAt: Date
        public let scannedFiles: Int
        public let unreadableFiles: Int
        public let scannedCLIFiles: Int

        public init(
            last5h: KiroUsageTotals,
            today: KiroUsageTotals,
            hourlyCredits: [Double],
            scannedAt: Date,
            scannedFiles: Int = 0,
            unreadableFiles: Int = 0,
            scannedCLIFiles: Int = 0
        ) {
            self.last5h = last5h
            self.today = today
            self.hourlyCredits = hourlyCredits
            self.scannedAt = scannedAt
            self.scannedFiles = scannedFiles
            self.unreadableFiles = unreadableFiles
            self.scannedCLIFiles = scannedCLIFiles
        }

        public var notice: String? {
            if unreadableFiles > 0 { return "Some Kiro local records could not be read" }
            if scannedFiles == 0 { return "No Kiro local usage records yet" }
            if last5h.isEmpty && today.isEmpty { return "No Kiro usage in the selected period" }
            return nil
        }
    }

    public struct FileCache: Sendable {
        fileprivate struct FileEntry: Sendable {
            var consumedBytes: UInt64 = 0
            var events: [CachedUsage] = []
            var seenIDs: Set<String> = []
            var modificationDate: Date?
        }

        fileprivate var files: [String: FileEntry] = [:]

        public init() {}
    }

    public static func scan(
        kiroHome: String = NSHomeDirectory() + "/.kiro",
        now: Date = Date()
    ) -> Snapshot {
        var cache = FileCache()
        return scan(kiroHome: kiroHome, now: now, cache: &cache)
    }

    public static func scan(
        kiroHome: String = NSHomeDirectory() + "/.kiro",
        now: Date = Date(),
        cache: inout FileCache
    ) -> Snapshot {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(sparklineHours) * 3600)
        let cutoff = min(fiveHoursAgo, midnight, sparklineStart)
        var last5h = KiroUsageTotals()
        var today = KiroUsageTotals()
        var hourly = [Double](repeating: 0, count: sparklineHours)
        var activePaths = Set<String>()
        var globallySeenIDs = Set<String>()
        var scannedFiles = 0
        var unreadableFiles = 0
        var scannedCLIFiles = 0

        let sessions = URL(fileURLWithPath: kiroHome).appendingPathComponent("sessions")
        let cliSessions = sessions.appendingPathComponent("cli").standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let files = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = files?.nextObject() as? URL {
            let isCLI = url.pathExtension == "json"
                && url.deletingLastPathComponent().standardizedFileURL == cliSessions
            guard url.lastPathComponent == "messages.jsonl" || isCLI,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff,
                  let size = values.fileSize else { continue }
            let path = url.path
            activePaths.insert(path)
            var entry = cache.files[path] ?? FileCache.FileEntry()
            let byteSize = UInt64(size)
            if isCLI {
                if byteSize != entry.consumedBytes || entry.modificationDate != values.contentModificationDate {
                    guard let data = try? Data(contentsOf: url), let events = parseCLIUsage(data) else {
                        entry.events.removeAll()
                        entry.seenIDs.removeAll()
                        entry.consumedBytes = byteSize
                        entry.modificationDate = values.contentModificationDate
                        cache.files[path] = entry
                        unreadableFiles += 1
                        continue
                    }
                    entry.events = events
                    entry.consumedBytes = byteSize
                    entry.modificationDate = values.contentModificationDate
                }
                scannedFiles += 1
                scannedCLIFiles += 1
            } else {
                if byteSize < entry.consumedBytes { entry = FileCache.FileEntry() }
                if byteSize > entry.consumedBytes, !consumeNewLines(path: path, into: &entry) {
                    unreadableFiles += 1
                } else {
                    scannedFiles += 1
                }
            }
            entry.events.removeAll { $0.timestamp < cutoff }
            cache.files[path] = entry

            for item in entry.events where item.timestamp <= now {
                guard globallySeenIDs.insert(item.id).inserted else { continue }
                if item.timestamp >= fiveHoursAgo { last5h.add(credits: item.credits) }
                if item.timestamp >= midnight { today.add(credits: item.credits) }
                let hoursAgo = Int(now.timeIntervalSince(item.timestamp) / 3600)
                if hoursAgo >= 0, hoursAgo < sparklineHours {
                    hourly[sparklineHours - 1 - hoursAgo] += item.credits
                }
            }
        }
        cache.files = cache.files.filter { activePaths.contains($0.key) }
        return Snapshot(
            last5h: last5h,
            today: today,
            hourlyCredits: hourly,
            scannedAt: now,
            scannedFiles: scannedFiles,
            unreadableFiles: unreadableFiles,
            scannedCLIFiles: scannedCLIFiles
        )
    }

    private static func parseCLIUsage(_ data: Data) -> [CachedUsage]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = root["session_id"] as? String, !sessionID.isEmpty else { return nil }
        let state = root["session_state"] as? [String: Any]
        let metadata = state?["conversation_metadata"] as? [String: Any]
        let turns = metadata?["user_turn_metadatas"] as? [[String: Any]] ?? []
        return turns.enumerated().compactMap { index, turn in
            guard let rawTimestamp = turn["end_timestamp"] as? String,
                  let timestamp = parseISO8601(rawTimestamp),
                  let metering = turn["metering_usage"] as? [[String: Any]] else { return nil }
            let values = metering.filter { ($0["unit"] as? String)?.lowercased() == "credit" }
                .compactMap { ($0["value"] as? NSNumber)?.doubleValue }
            guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            let credits = values.reduce(0, +)
            guard credits.isFinite else { return nil }
            return CachedUsage(id: "cli:\(sessionID):\(index):\(rawTimestamp)", timestamp: timestamp, credits: credits)
        }
    }

    private static func consumeNewLines(path: String, into entry: inout FileCache.FileEntry) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: entry.consumedBytes)
        var fragment = Data()

        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            var data = fragment
            data.append(chunk)
            var lineStart = data.startIndex
            for index in data.indices where data[index] == 0x0A {
                apply(line: Data(data[lineStart..<index]), to: &entry)
                lineStart = data.index(after: index)
            }
            fragment = Data(data[lineStart..<data.endIndex])
            entry.consumedBytes += UInt64(data.count - fragment.count)
        }

        if !fragment.isEmpty, let item = parseUsageSummary(String(data: fragment, encoding: .utf8) ?? "") {
            if entry.seenIDs.insert(item.id).inserted {
                entry.events.append(CachedUsage(id: item.id, timestamp: item.timestamp, credits: item.credits))
            }
            entry.consumedBytes += UInt64(fragment.count)
        }
        return true
    }

    private static func apply(line data: Data, to entry: inout FileCache.FileEntry) {
        guard let item = parseUsageSummary(String(data: data, encoding: .utf8) ?? ""),
              entry.seenIDs.insert(item.id).inserted else { return }
        entry.events.append(CachedUsage(id: item.id, timestamp: item.timestamp, credits: item.credits))
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
