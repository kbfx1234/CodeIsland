import Foundation

private struct CachedCodexUsage: Sendable {
    let key: String
    let timestamp: Date
    let model: String
    let source: CodexAccessKind
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
}

public struct CodexUsageTotals: Equatable, Sendable {
    public var inputTokens = 0
    public var cachedInputTokens = 0
    public var cacheWriteTokens = 0
    public var outputTokens = 0
    public var turnCount = 0

    public init() {}

    public var totalTokens: Int {
        inputTokens + cachedInputTokens + cacheWriteTokens + outputTokens
    }

    fileprivate mutating func add(_ event: CachedCodexUsage) {
        inputTokens += event.inputTokens
        cachedInputTokens += event.cachedInputTokens
        cacheWriteTokens += event.cacheWriteTokens
        outputTokens += event.outputTokens
        turnCount += 1
    }
}

public struct CodexUsageSourceSnapshot: Equatable, Sendable {
    public let source: CodexAccessKind
    public let last5h: CodexUsageTotals
    public let today: CodexUsageTotals

    public init(source: CodexAccessKind, last5h: CodexUsageTotals, today: CodexUsageTotals) {
        self.source = source
        self.last5h = last5h
        self.today = today
    }
}

public enum CodexUsageScanner {
    public static let sparklineHours = 12

    public struct Snapshot: Equatable, Sendable {
        public let last5h: CodexUsageTotals
        public let today: CodexUsageTotals
        public let hourlyOutputTokens: [Int]
        public let bySource: [CodexAccessKind: CodexUsageSourceSnapshot]
        public let scannedAt: Date

        public init(
            last5h: CodexUsageTotals,
            today: CodexUsageTotals,
            hourlyOutputTokens: [Int],
            bySource: [CodexAccessKind: CodexUsageSourceSnapshot],
            scannedAt: Date
        ) {
            self.last5h = last5h
            self.today = today
            self.hourlyOutputTokens = hourlyOutputTokens
            self.bySource = bySource
            self.scannedAt = scannedAt
        }

        public func usage(for source: CodexAccessKind) -> CodexUsageSourceSnapshot? {
            bySource[source]
        }
    }

    public struct FileCache: Sendable {
        fileprivate struct FileEntry: Sendable {
            var consumedBytes: UInt64 = 0
            var events: [CachedCodexUsage] = []
            var seenKeys: Set<String> = []
            var model: String?
            var source: CodexAccessKind = .unknown
            var sessionID: String?
        }

        fileprivate var files: [String: FileEntry] = [:]

        public init() {}
    }

    public static func scan(
        codexHome: String? = nil,
        now: Date = Date(),
        fallbackSource: CodexAccessKind = .unknown
    ) -> Snapshot {
        var cache = FileCache()
        return scan(codexHome: codexHome, now: now, fallbackSource: fallbackSource, cache: &cache)
    }

    public static func scan(
        codexHome: String? = nil,
        now: Date = Date(),
        fallbackSource: CodexAccessKind = .unknown,
        cache: inout FileCache
    ) -> Snapshot {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 60 * 60)
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(sparklineHours) * 60 * 60)
        let cutoff = min(fiveHoursAgo, midnight, sparklineStart)
        let root = URL(fileURLWithPath: codexHome ?? defaultCodexHome(), isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        var allFiveHour = CodexUsageTotals()
        var allToday = CodexUsageTotals()
        var hourly = [Int](repeating: 0, count: sparklineHours)
        var sourceTotals: [CodexAccessKind: (CodexUsageTotals, CodexUsageTotals)] = [:]
        var activePaths = Set<String>()
        var globallySeenKeys = Set<String>()

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }

            let path = url.path
            activePaths.insert(path)
            var entry = cache.files[path] ?? FileCache.FileEntry()
            let size = UInt64(values.fileSize ?? 0)
            if size < entry.consumedBytes { entry = FileCache.FileEntry() }
            if size > entry.consumedBytes { consumeNewLines(path: path, into: &entry) }
            entry.events.removeAll { $0.timestamp < cutoff }
            if entry.source == .unknown { entry.source = fallbackSource }
            cache.files[path] = entry

            for event in entry.events where event.timestamp <= now {
                if event.key.hasPrefix("session:") && !globallySeenKeys.insert(event.key).inserted {
                    continue
                }
                let source = event.source == .unknown ? fallbackSource : event.source
                if event.timestamp >= fiveHoursAgo {
                    allFiveHour.add(event)
                    sourceTotals[source, default: (CodexUsageTotals(), CodexUsageTotals())].0.add(event)
                }
                if event.timestamp >= midnight {
                    allToday.add(event)
                    sourceTotals[source, default: (CodexUsageTotals(), CodexUsageTotals())].1.add(event)
                }
                let hoursAgo = Int(now.timeIntervalSince(event.timestamp) / 3600)
                if hoursAgo >= 0 && hoursAgo < sparklineHours {
                    hourly[sparklineHours - 1 - hoursAgo] += event.outputTokens
                }
            }
        }

        cache.files = cache.files.filter { activePaths.contains($0.key) }
        let bySource = Dictionary(uniqueKeysWithValues: sourceTotals.map { source, totals in
            (source, CodexUsageSourceSnapshot(source: source, last5h: totals.0, today: totals.1))
        })
        return Snapshot(last5h: allFiveHour, today: allToday, hourlyOutputTokens: hourly,
                        bySource: bySource, scannedAt: now)
    }

    private struct ParsedLine {
        let event: CachedCodexUsage?
        let model: String?
        let source: CodexAccessKind?

        let sessionID: String?

        init(
            event: CachedCodexUsage?,
            model: String?,
            source: CodexAccessKind?,
            sessionID: String? = nil
        ) {
            self.event = event
            self.model = model
            self.source = source
            self.sessionID = sessionID
        }
    }

    private static func defaultCodexHome() -> String {
        let raw = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return NSHomeDirectory() + "/" + raw.dropFirst(2) }
        return raw.isEmpty ? NSHomeDirectory() + "/.codex" : raw
    }

    public static func classifyModelProvider(_ value: String?) -> CodexAccessKind {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return .unknown }
        if value == "openai" || value == "chatgpt" || value == "default" { return .officialSubscription }
        if ["router", "proxy", "gateway", "relay"].contains(where: value.contains) { return .apiRouter }
        return .apiRouter
    }

    public static func formatTokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        let value = Double(count)
        if count < 1_000_000 { return String(format: "%.1fK", value / 1_000).replacingOccurrences(of: ".0K", with: "K") }
        if count < 1_000_000_000 { return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        return String(format: "%.1fB", value / 1_000_000_000).replacingOccurrences(of: ".0B", with: "B")
    }

    private static func consumeNewLines(path: String, into entry: inout FileCache.FileEntry) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
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
                let line = Data(data[lineStart..<index])
                apply(parseLine(line), to: &entry)
                lineStart = data.index(after: index)
            }
            fragment = Data(data[lineStart..<data.endIndex])
            entry.consumedBytes += UInt64(data.count - fragment.count)
        }
        // A trailing partial line is intentionally left unconsumed. The next
        // scan starts at the same offset and retries it after the writer closes it.
    }

    private static func apply(_ parsed: ParsedLine, to entry: inout FileCache.FileEntry) {
        if let model = parsed.model { entry.model = model }
        if let source = parsed.source { entry.source = source }
        if let sessionID = parsed.sessionID { entry.sessionID = sessionID }
        guard let event = parsed.event else { return }
        let key = entry.sessionID.map { "session:\($0):\(event.key)" } ?? event.key
        guard entry.seenKeys.insert(key).inserted else { return }
        entry.events.append(CachedCodexUsage(
            key: key,
            timestamp: event.timestamp,
            model: event.model.isEmpty ? (entry.model ?? "unknown") : event.model,
            source: event.source == .unknown ? entry.source : event.source,
            inputTokens: event.inputTokens,
            cachedInputTokens: event.cachedInputTokens,
            cacheWriteTokens: event.cacheWriteTokens,
            outputTokens: event.outputTokens
        ))
    }

    private static func parseLine(_ data: Data) -> ParsedLine {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else {
            return ParsedLine(event: nil, model: nil, source: nil)
        }

        if type == "session_meta", let payload = root["payload"] as? [String: Any] {
            return ParsedLine(
                event: nil,
                model: payload["model"] as? String,
                source: (payload["model_provider"] as? String).map(classifyModelProvider),
                sessionID: (payload["id"] as? String) ?? (payload["session_id"] as? String)
            )
        }
        guard type == "turn_context" || type == "event_msg" else {
            return ParsedLine(event: nil, model: nil, source: nil)
        }

        guard let payload = root["payload"] as? [String: Any] else {
            return ParsedLine(event: nil, model: nil, source: nil)
        }
        if type == "turn_context" {
            return ParsedLine(
                event: nil,
                model: payload["model"] as? String,
                source: (payload["model_provider"] as? String).map(classifyModelProvider)
            )
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let timestamp = parseDate(root["timestamp"] as? String) else {
            return ParsedLine(event: nil, model: nil, source: nil)
        }

        let input = integer(last["input_tokens"])
        let cached = integer(last["cached_input_tokens"])
        let cacheWrite = integer(last["cache_write_input_tokens"] ?? last["cache_creation_input_tokens"])
        let output = integer(last["output_tokens"])
        guard input >= 0, cached >= 0, cacheWrite >= 0, output >= 0,
              input > 0 || cached > 0 || cacheWrite > 0 || output > 0 else {
            return ParsedLine(event: nil, model: nil, source: nil)
        }

        let ordinal = scalarString(root["ordinal"])
        let key = ordinal.map { "ordinal:\($0)" }
            ?? "usage:\(timestamp.timeIntervalSince1970.bitPattern):\(input):\(cached):\(cacheWrite):\(output)"
        return ParsedLine(
            event: CachedCodexUsage(
                key: key,
                timestamp: timestamp,
                model: "",
                source: .unknown,
                inputTokens: max(0, input - cached),
                cachedInputTokens: cached,
                cacheWriteTokens: cacheWrite,
                outputTokens: output
            ),
            model: nil,
            source: nil
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func integer(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
