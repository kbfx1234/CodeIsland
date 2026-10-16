import Foundation

public enum CodexQuotaWindowKind: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case weekly

    public var span: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }
}

public struct CodexQuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let resetAt: Date?

    public init(usedPercent: Double?, resetAt: Date?) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }

    public var hasReading: Bool { usedPercent != nil }

    public static let unknown = CodexQuotaWindow(usedPercent: nil, resetAt: nil)
}

public struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
    public let fiveHour: CodexQuotaWindow
    public let weekly: CodexQuotaWindow
    public let planType: String?
    public let fetchedAt: Date

    public init(
        fiveHour: CodexQuotaWindow,
        weekly: CodexQuotaWindow,
        planType: String? = nil,
        fetchedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planType = planType
        self.fetchedAt = fetchedAt
    }

    public func window(_ kind: CodexQuotaWindowKind) -> CodexQuotaWindow {
        kind == .fiveHour ? fiveHour : weekly
    }
}

public enum CodexQuotaFetchError: Error, Equatable, Sendable {
    case authenticationRequired
    case rateLimited
    case invalidResponse
    case httpStatus(Int)
    case transport(String)
}

public enum CodexQuotaClient {
    public typealias Request = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func fetch(
        accessToken: String,
        now: Date = Date(),
        request: Request = { try await URLSession.shared.data(for: $0) }
    ) async throws -> CodexQuotaSnapshot {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await request(urlRequest)
        } catch {
            throw CodexQuotaFetchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexQuotaFetchError.invalidResponse
        }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw CodexQuotaFetchError.authenticationRequired
        case 429: throw CodexQuotaFetchError.rateLimited
        default: throw CodexQuotaFetchError.httpStatus(http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any]
        else { throw CodexQuotaFetchError.invalidResponse }

        let routed = routeWindows(rateLimit)
        guard routed.fiveHour != nil || routed.weekly != nil else {
            throw CodexQuotaFetchError.invalidResponse
        }
        return CodexQuotaSnapshot(
            fiveHour: routed.fiveHour ?? .unknown,
            weekly: routed.weekly ?? .unknown,
            planType: root["plan_type"] as? String,
            fetchedAt: now
        )
    }

    public static func routeWindows(_ rateLimit: [String: Any]) -> (
        fiveHour: CodexQuotaWindow?, weekly: CodexQuotaWindow?
    ) {
        var fiveHour: CodexQuotaWindow?
        var weekly: CodexQuotaWindow?

        for (key, fallback) in [("primary_window", CodexQuotaWindowKind.fiveHour),
                                ("secondary_window", CodexQuotaWindowKind.weekly)] {
            guard let raw = rateLimit[key] as? [String: Any] else { continue }
            let span = numeric(raw["limit_window_seconds"])
            let kind = span.map { $0 >= 24 * 60 * 60 ? CodexQuotaWindowKind.weekly : .fiveHour } ?? fallback
            let window = parseWindow(raw)
            switch kind {
            case .fiveHour: if fiveHour == nil { fiveHour = window }
            case .weekly: if weekly == nil { weekly = window }
            }
        }
        return (fiveHour, weekly)
    }

    private static func parseWindow(_ raw: [String: Any]) -> CodexQuotaWindow {
        let used = numeric(raw["used_percent"]).map { min(1, max(0, $0 / 100)) }
        let reset = numeric(raw["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return CodexQuotaWindow(usedPercent: used, resetAt: reset)
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
