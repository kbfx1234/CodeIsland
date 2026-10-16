import Foundation

/// Account-level Kiro billing cached by the Kiro IDE. This is separate from
/// local session activity and may include CLI, IDE, and web usage.
public struct KiroAccountUsageSnapshot: Equatable, Sendable {
    public let currentUsage: Double
    public let usageLimit: Double
    public let percentageUsed: Double
    public let currentOverages: Double
    public let resetAt: Date
    public let sourceUpdatedAt: Date?
    public let fetchedAt: Date

    public init(
        currentUsage: Double,
        usageLimit: Double,
        percentageUsed: Double,
        currentOverages: Double,
        resetAt: Date,
        sourceUpdatedAt: Date? = nil,
        fetchedAt: Date
    ) {
        self.currentUsage = currentUsage
        self.usageLimit = usageLimit
        self.percentageUsed = percentageUsed
        self.currentOverages = currentOverages
        self.resetAt = resetAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.fetchedAt = fetchedAt
    }

    public var remaining: Double { usageLimit - currentUsage }
}

public enum KiroAccountUsageParser {
    public static func parse(data: Data, fetchedAt: Date = Date()) -> KiroAccountUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["kiro.resourceNotifications.usageState"] as? [String: Any],
              let breakdowns = state["usageBreakdowns"] as? [[String: Any]],
              let breakdown = breakdowns.first(where: { isCreditBreakdown($0) }),
              let current = number(breakdown["currentUsage"]),
              let limit = number(breakdown["usageLimit"]),
              current.isFinite, limit.isFinite, limit > 0,
              let resetAt = date(breakdown["resetDate"]) else { return nil }

        let percentage = number(breakdown["percentageUsed"]) ?? current / limit * 100
        let overages = number(breakdown["currentOverages"]) ?? max(0, current - limit)
        guard percentage.isFinite, overages.isFinite else { return nil }
        return KiroAccountUsageSnapshot(
            currentUsage: current,
            usageLimit: limit,
            percentageUsed: percentage,
            currentOverages: overages,
            resetAt: resetAt,
            sourceUpdatedAt: timestamp(state["timestamp"]),
            fetchedAt: fetchedAt
        )
    }

    private static func isCreditBreakdown(_ value: [String: Any]) -> Bool {
        let type = (value["type"] as? String)?.lowercased() ?? ""
        let name = (value["displayName"] as? String)?.lowercased() ?? ""
        let plural = (value["displayNamePlural"] as? String)?.lowercased() ?? ""
        return type == "credit" || name == "credit" || name == "credits" || plural == "credits"
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}
