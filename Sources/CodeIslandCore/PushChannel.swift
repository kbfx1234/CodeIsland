import Foundation
import CryptoKit

// MARK: - Channels

/// Delivery services. Formats and signing follow each vendor's own docs:
/// - Bark: github.com/Finb/bark-server/blob/master/docs/API_V2.md
/// - ntfy: docs.ntfy.sh/publish (#publish-as-json, #access-tokens)
/// - DingTalk: open.dingtalk.com/document/orgapp/customize-robot-security-settings
///   and …/custom-robots-send-group-messages
/// - Feishu / Lark: open.feishu.cn/document/client-docs/bot-v3/add-custom-bot
/// - WeCom: developer.work.weixin.qq.com/document/path/91770
/// - Slack: docs.slack.dev/messaging/sending-messages-using-incoming-webhooks
/// - Telegram: core.telegram.org/bots/api#sendmessage
public enum PushChannelKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case bark
    case ntfy
    case dingtalk
    case feishu
    case wecom
    case slack
    case telegram

    public var id: String { rawValue }

    /// Hosted default for services that have one; the rest take a webhook URL.
    public var defaultEndpoint: String {
        switch self {
        case .bark: return "https://api.day.app"
        case .ntfy: return "https://ntfy.sh"
        case .telegram: return "https://api.telegram.org"
        case .dingtalk, .feishu, .wecom, .slack: return ""
        }
    }

    /// A team chat: everyone in the group reads what is posted, so a new
    /// channel sends headlines only (`PushChannelConfig.includeDetails`).
    public var isGroupChat: Bool {
        switch self {
        case .dingtalk, .feishu, .wecom, .slack: return true
        case .bark, .ntfy, .telegram: return false
        }
    }
}

/// Why a channel can't send yet. The settings UI shows it inline, and a test
/// send reports it instead of making a request that is bound to fail.
public enum PushConfigProblem: String, Error, Sendable {
    case missingDeviceKey
    case missingTopic
    case missingWebhook
    case missingBotToken
    case missingChatId
    case invalidURL
    /// ntfy: Server already ends in a topic, and Topic names another one.
    case ntfyTopicMismatch
}

/// One channel's settings. A flat record rather than one type per service:
/// the fields mean different things per `kind` (documented below), and a
/// flat record keeps the stored JSON and the settings bindings simple.
public struct PushChannelConfig: Codable, Equatable, Sendable, Identifiable {
    public var kind: PushChannelKind
    public var enabled: Bool
    public var events: Set<PushEventKind>
    /// Bark / ntfy server, Telegram API base (for a local Bot API server), or
    /// the full webhook URL (DingTalk, Feishu, WeCom, Slack). May carry
    /// `user:password@` for a self-hosted server behind basic auth.
    public var endpoint: String
    /// Bark device key, ntfy topic, Telegram chat_id.
    public var target: String
    /// ntfy access token, Telegram bot token.
    public var token: String
    /// DingTalk "加签" secret (SEC…), Feishu / Lark signature secret.
    public var secret: String
    /// Bark only.
    public var group: String
    public var icon: String
    public var sound: String
    /// ntfy priority (1–5) for pushes that block an agent; the rest go at
    /// the default priority 3, or lower if the user picked lower.
    public var priority: Int
    /// Commands, replies, error text and question options. Off, a push says
    /// only who, which project and what happened (tool name / question
    /// label). Defaults off for team chats, on for personal channels —
    /// also for settings saved before this switch existed.
    public var includeDetails: Bool

    public var id: String { kind.rawValue }

    public static let defaultPriority = 4

    public init(kind: PushChannelKind) {
        self.kind = kind
        self.enabled = false
        self.events = PushEventKind.defaultSelection
        self.endpoint = kind.defaultEndpoint
        self.target = ""
        self.token = ""
        self.secret = ""
        self.group = ""
        self.icon = ""
        self.sound = ""
        self.priority = Self.defaultPriority
        self.includeDetails = !kind.isGroupChat
    }

    private enum CodingKeys: String, CodingKey {
        case kind, enabled, events, endpoint, target, token, secret, group, icon, sound, priority, includeDetails
    }

    /// Every field but `kind` is optional on decode, and unknown event names
    /// are dropped, so settings written by a newer build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(PushChannelKind.self, forKey: .kind))
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        if let raw = try c.decodeIfPresent([String].self, forKey: .events) {
            events = Set(raw.compactMap(PushEventKind.init(rawValue:)))
        }
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? target
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? token
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? secret
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? group
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? icon
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? sound
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? priority
        includeDetails = try c.decodeIfPresent(Bool.self, forKey: .includeDetails) ?? includeDetails
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(events.map(\.rawValue).sorted(), forKey: .events)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(target, forKey: .target)
        try c.encode(token, forKey: .token)
        try c.encode(secret, forKey: .secret)
        try c.encode(group, forKey: .group)
        try c.encode(icon, forKey: .icon)
        try c.encode(sound, forKey: .sound)
        try c.encode(priority, forKey: .priority)
        try c.encode(includeDetails, forKey: .includeDetails)
    }

    /// First reason this channel cannot send, or nil when it can.
    public var problem: PushConfigProblem? {
        do {
            _ = try PushRequestBuilder.request(
                for: PushMessage(kind: .completion, sessionId: "", title: "", headline: "", body: ""),
                channel: self,
                now: Date(timeIntervalSince1970: 0)
            )
            return nil
        } catch let problem as PushConfigProblem {
            return problem
        } catch {
            return .invalidURL
        }
    }

    public var isConfigured: Bool { problem == nil }

    /// Whether this channel takes a push of `kind` right now.
    public func accepts(_ kind: PushEventKind) -> Bool {
        enabled && events.contains(kind) && isConfigured
    }

    /// One config per channel kind, in `allCases` order. Missing or
    /// unreadable entries come back as defaults (disabled), so a corrupt
    /// setting disables pushes rather than crashing or half-applying.
    public static func decodeList(_ json: String) -> [PushChannelConfig] {
        var byKind: [PushChannelKind: PushChannelConfig] = [:]
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([FailableConfig].self, from: data) {
            for entry in decoded {
                if let config = entry.config, byKind[config.kind] == nil {
                    byKind[config.kind] = config
                }
            }
        }
        return PushChannelKind.allCases.map { byKind[$0] ?? PushChannelConfig(kind: $0) }
    }

    public static func encodeList(_ configs: [PushChannelConfig]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(configs) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Skips an entry whose kind this build doesn't know instead of failing the list.
    private struct FailableConfig: Decodable {
        let config: PushChannelConfig?
        init(from decoder: Decoder) throws {
            config = try? PushChannelConfig(from: decoder)
        }
    }
}

// MARK: - HTTP request

public struct PushHTTPRequest: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    public func urlRequest(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return request
    }

    /// Decoded JSON body, for tests and diagnostics.
    public var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

public enum PushRequestBuilder {
    public static let userAgent = "CodeIsland-Push/1.0"
    /// Footer on group-chat bots, so DingTalk / Feishu "custom keyword"
    /// security can be satisfied with the keyword "CodeIsland".
    public static let keywordFooter = "— CodeIsland"

    /// Bark relays through APNs, whose payload limit is 4096 bytes in total
    /// — title, subtitle, group and bark-server's own fields included — so
    /// the body is cut in bytes: 1 000 emoji or CJK characters would be 3–4 KB.
    static let barkBodyBytes = 2_500
    static let barkTitleLimit = 120
    static let barkSubtitleLimit = 200
    /// ntfy turns longer messages into attachments (default limit 4096 bytes).
    static let ntfyMessageBytes = 3_800
    /// WeCom text content: at most 2048 UTF-8 bytes.
    static let wecomContentBytes = 2_048
    /// Telegram: 1–4096 characters after entity parsing, counted in UTF-16
    /// code units (an emoji is two, a family emoji eight).
    static let telegramTextLimit = 3_900
    static let chatTextLimit = 4_000
    static let slackTextLimit = 3_000

    public static func request(
        for message: PushMessage,
        channel: PushChannelConfig,
        now: Date = Date()
    ) throws -> PushHTTPRequest {
        switch channel.kind {
        case .bark: return try bark(message, channel)
        case .ntfy: return try ntfy(message, channel)
        case .dingtalk: return try dingTalk(message, channel, now: now)
        case .feishu: return try feishu(message, channel, now: now)
        case .wecom: return try weCom(message, channel)
        case .slack: return try slack(message, channel)
        case .telegram: return try telegram(message, channel)
        }
    }

    // MARK: Bark

    /// POST {server}/push with a JSON body (API v2). Blocking pushes use
    /// level `timeSensitive`, which breaks through Focus.
    static func bark(_ message: PushMessage, _ channel: PushChannelConfig) throws -> PushHTTPRequest {
        let serverText = nonEmpty(channel.endpoint) ?? PushChannelKind.bark.defaultEndpoint
        guard let server = PushEndpoint.parse(serverText) else { throw PushConfigProblem.invalidURL }
        var base = server.url
        var deviceKey = nonEmpty(channel.target)
        if deviceKey == nil {
            // The Bark app hands out "https://api.day.app/<key>/"; accept it
            // pasted whole into the server field.
            let components = PushEndpoint.pathComponents(of: base)
            if let last = components.last, last != "push" {
                deviceKey = last
                base = PushEndpoint.replacingPath(of: base, with: components.dropLast())
            }
        }
        guard let deviceKey else { throw PushConfigProblem.missingDeviceKey }
        var components = PushEndpoint.pathComponents(of: base)
        if components.last == deviceKey {
            // Key both pasted in the URL and typed into its own field.
            components.removeLast()
            base = PushEndpoint.replacingPath(of: base, with: components)
        }
        let url = components.last == "push"
            ? base
            : PushEndpoint.replacingPath(of: base, with: components + ["push"])

        var body: [String: Any] = [
            "device_key": deviceKey,
            "title": PushMessageFormatter.truncated(message.title, limit: barkTitleLimit),
            "level": message.blocksAgent ? "timeSensitive" : "active",
            "group": nonEmpty(channel.group) ?? "CodeIsland",
        ]
        let headline = PushMessageFormatter.truncated(message.headline, limit: barkSubtitleLimit)
        // Bark requires a body; an empty one falls back to the headline.
        if message.body.isEmpty {
            body["body"] = headline
        } else {
            body["subtitle"] = headline
            body["body"] = PushMessageFormatter.truncated(message.body, maxUTF8Bytes: barkBodyBytes)
        }
        if let icon = nonEmpty(channel.icon) { body["icon"] = icon }
        if let sound = nonEmpty(channel.sound) { body["sound"] = sound }
        return try jsonRequest(url: url, body: body, authorization: server.authorization)
    }

    // MARK: ntfy

    /// POST {server}/ with `{"topic", "title", "message", "priority"}`.
    /// Auth: `Authorization: Bearer <token>`, or basic auth from the URL.
    ///
    /// JSON has to go to the server root: POSTed to `/<topic>`, ntfy
    /// publishes the whole JSON document as the text of a message to that
    /// topic and still answers 200. So a topic at the end of Server is taken
    /// out — it is the topic when Topic is empty, a repeat of it when equal,
    /// and a contradiction the user has to resolve when not.
    static func ntfy(_ message: PushMessage, _ channel: PushChannelConfig) throws -> PushHTTPRequest {
        let serverText = nonEmpty(channel.endpoint) ?? PushChannelKind.ntfy.defaultEndpoint
        guard let server = PushEndpoint.parse(serverText) else { throw PushConfigProblem.invalidURL }
        var components = PushEndpoint.pathComponents(of: server.url)
        var topic = nonEmpty(channel.target)
        if let last = components.last {
            if topic == nil {
                // "https://ntfy.sh/mytopic" pasted whole.
                topic = last
            } else if last != topic {
                throw PushConfigProblem.ntfyTopicMismatch
            }
            components.removeLast()
        }
        guard let topic else { throw PushConfigProblem.missingTopic }
        let urgent = min(max(channel.priority, 1), 5)
        let priority = message.blocksAgent ? urgent : min(urgent, 3)
        let body: [String: Any] = [
            "topic": topic,
            "title": message.title,
            "message": PushMessageFormatter.truncated(message.text, maxUTF8Bytes: ntfyMessageBytes),
            "priority": priority,
        ]
        var authorization = server.authorization
        if let token = nonEmpty(channel.token) {
            authorization = token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
        }
        let url = PushEndpoint.replacingPath(of: server.url, with: components)
        return try jsonRequest(url: url, body: body, authorization: authorization)
    }

    // MARK: DingTalk

    /// Custom robot: POST the webhook with a text message. With "加签"
    /// enabled, `timestamp` (ms) and the URL-encoded `sign` go on the URL.
    static func dingTalk(_ message: PushMessage, _ channel: PushChannelConfig, now: Date) throws -> PushHTTPRequest {
        guard let webhook = nonEmpty(channel.endpoint) else { throw PushConfigProblem.missingWebhook }
        guard let endpoint = PushEndpoint.parse(webhook) else { throw PushConfigProblem.invalidURL }
        var url = endpoint.url
        if let secret = nonEmpty(channel.secret) {
            let timestamp = Int64((now.timeIntervalSince1970 * 1000).rounded())
            let sign = PushSigning.dingTalkSignature(secret: secret, timestampMillis: timestamp)
            url = PushEndpoint.settingQuery(of: url, [
                ("timestamp", String(timestamp)),
                ("sign", PushSigning.formURLEncoded(sign)),
            ])
        }
        let content = PushMessageFormatter.truncated(chatText(message, footer: true), limit: chatTextLimit)
        let body: [String: Any] = ["msgtype": "text", "text": ["content": content]]
        return try jsonRequest(url: url, body: body, authorization: endpoint.authorization)
    }

    // MARK: Feishu / Lark

    /// Custom bot: POST the webhook with a rich-text ("post") message, whose
    /// title renders bold. With signature verification on, `timestamp` (s,
    /// as a string) and `sign` go in the JSON body.
    static func feishu(_ message: PushMessage, _ channel: PushChannelConfig, now: Date) throws -> PushHTTPRequest {
        guard let webhook = nonEmpty(channel.endpoint) else { throw PushConfigProblem.missingWebhook }
        guard let endpoint = PushEndpoint.parse(webhook) else { throw PushConfigProblem.invalidURL }
        let text = PushMessageFormatter.truncated(
            [message.text, keywordFooter].joined(separator: "\n"),
            limit: chatTextLimit
        )
        let paragraphs: [[[String: Any]]] = text
            .components(separatedBy: "\n")
            .map { [["tag": "text", "text": $0]] }
        var body: [String: Any] = [
            "msg_type": "post",
            "content": [
                "post": [
                    "zh_cn": [
                        "title": message.title,
                        "content": paragraphs,
                    ] as [String: Any],
                ],
            ],
        ]
        if let secret = nonEmpty(channel.secret) {
            let timestamp = Int64(now.timeIntervalSince1970.rounded(.down))
            body["timestamp"] = String(timestamp)
            body["sign"] = PushSigning.feishuSignature(secret: secret, timestampSeconds: timestamp)
        }
        return try jsonRequest(url: endpoint.url, body: body, authorization: endpoint.authorization)
    }

    // MARK: WeCom

    /// Group robot: POST the webhook with a text message (≤ 2048 bytes).
    static func weCom(_ message: PushMessage, _ channel: PushChannelConfig) throws -> PushHTTPRequest {
        guard let webhook = nonEmpty(channel.endpoint) else { throw PushConfigProblem.missingWebhook }
        guard let endpoint = PushEndpoint.parse(webhook) else { throw PushConfigProblem.invalidURL }
        let content = PushMessageFormatter.truncated(chatText(message, footer: false), maxUTF8Bytes: wecomContentBytes)
        let body: [String: Any] = ["msgtype": "text", "text": ["content": content]]
        return try jsonRequest(url: endpoint.url, body: body, authorization: endpoint.authorization)
    }

    // MARK: Slack

    /// Incoming webhook: `{"text"}` with `&`, `<`, `>` escaped (Slack reads
    /// `<…>` as link syntax) and mrkdwn off so `*`/`_` in commands stay literal.
    static func slack(_ message: PushMessage, _ channel: PushChannelConfig) throws -> PushHTTPRequest {
        guard let webhook = nonEmpty(channel.endpoint) else { throw PushConfigProblem.missingWebhook }
        guard let endpoint = PushEndpoint.parse(webhook) else { throw PushConfigProblem.invalidURL }
        let text = PushMessageFormatter.truncated(chatText(message, footer: false), limit: slackTextLimit)
        let body: [String: Any] = ["text": htmlEscaped(text), "mrkdwn": false]
        return try jsonRequest(url: endpoint.url, body: body, authorization: endpoint.authorization)
    }

    // MARK: Telegram

    /// POST {api}/bot<token>/sendMessage, HTML parse mode with a bold title.
    static func telegram(_ message: PushMessage, _ channel: PushChannelConfig) throws -> PushHTTPRequest {
        guard var token = nonEmpty(channel.token) else { throw PushConfigProblem.missingBotToken }
        guard let chatId = nonEmpty(channel.target) else { throw PushConfigProblem.missingChatId }
        // BotFather's token is "123:ABC"; people also paste the URL form "bot123:ABC".
        if token.hasPrefix("bot"), token.dropFirst(3).first?.isNumber == true {
            token.removeFirst(3)
        }
        let apiText = nonEmpty(channel.endpoint) ?? PushChannelKind.telegram.defaultEndpoint
        guard let api = PushEndpoint.parse(apiText) else { throw PushConfigProblem.invalidURL }
        let components = PushEndpoint.pathComponents(of: api.url) + ["bot\(token)", "sendMessage"]
        let url = PushEndpoint.replacingPath(of: api.url, with: components)
        // Title, newline and body share the limit; the <b> tags and the
        // entities htmlEscaped adds count as nothing after parsing.
        let bodyText = PushMessageFormatter.truncated(
            message.text,
            maxUTF16: max(telegramTextLimit - message.title.utf16.count - 1, 100)
        )
        let html = "<b>\(htmlEscaped(message.title))</b>\n\(htmlEscaped(bodyText))"
        let body: [String: Any] = [
            "chat_id": chatId,
            "text": html,
            "parse_mode": "HTML",
            "link_preview_options": ["is_disabled": true],
        ]
        return try jsonRequest(url: url, body: body, authorization: api.authorization)
    }

    // MARK: Helpers

    /// Title, headline and body as lines — for chat bots with no title slot.
    static func chatText(_ message: PushMessage, footer: Bool) -> String {
        var lines = [message.title, message.text]
        if footer { lines.append(keywordFooter) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Slack's and Telegram's HTML-ish escaping: exactly `&`, `<`, `>`.
    public static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func jsonRequest(url: URL, body: [String: Any], authorization: String?) throws -> PushHTTPRequest {
        guard let data = try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { throw PushConfigProblem.invalidURL }
        var headers = [
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": userAgent,
        ]
        if let authorization { headers["Authorization"] = authorization }
        return PushHTTPRequest(url: url, headers: headers, body: data)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - URLs

public enum PushEndpoint {
    /// Parses a user-typed URL. Adds `https://` when the scheme is missing
    /// and moves `user:password@` out of the URL into a Basic
    /// `Authorization` value — sent explicitly rather than trusting the URL
    /// loader to answer a 401 challenge with credentials it found in the URL.
    public static func parse(_ raw: String) -> (url: URL, authorization: String?)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        var authorization: String?
        if let user = components.user, !user.isEmpty {
            let credential = "\(user):\(components.password ?? "")"
            authorization = "Basic " + Data(credential.utf8).base64EncodedString()
        }
        components.user = nil
        components.password = nil
        guard let url = components.url else { return nil }
        return (url, authorization)
    }

    /// Non-empty path segments, percent-decoded.
    public static func pathComponents(of url: URL) -> [String] {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        return path.split(separator: "/").map(String.init)
    }

    /// Same scheme/host/port/query with the path rebuilt from `components`.
    public static func replacingPath<S: Sequence>(of url: URL, with components: S) -> URL where S.Element == String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let joined = components.joined(separator: "/")
        parts.path = "/" + joined
        return parts.url ?? url
    }

    /// Replaces (or adds) query items whose values are already percent-encoded.
    /// URLComponents' own encoding leaves `+` alone, which servers decode as
    /// a space — fatal for a Base64 signature.
    public static func settingQuery(of url: URL, _ items: [(name: String, encodedValue: String)]) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let names = Set(items.map(\.name))
        var query = (parts.percentEncodedQueryItems ?? []).filter { !names.contains($0.name) }
        query += items.map { URLQueryItem(name: $0.name, value: $0.encodedValue) }
        parts.percentEncodedQueryItems = query
        return parts.url ?? url
    }
}

// MARK: - Signing

public enum PushSigning {
    /// DingTalk "加签": Base64(HMAC-SHA256(key: secret,
    /// message: "\(timestampMillis)\n\(secret)")). The caller URL-encodes it.
    public static func dingTalkSignature(secret: String, timestampMillis: Int64) -> String {
        let stringToSign = "\(timestampMillis)\n\(secret)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return Data(mac).base64EncodedString()
    }

    /// Feishu / Lark: Base64(HMAC-SHA256(key: "\(timestampSeconds)\n\(secret)",
    /// message: empty)). Note the inversion against DingTalk — Feishu keys
    /// the MAC with the string-to-sign and signs nothing.
    public static func feishuSignature(secret: String, timestampSeconds: Int64) -> String {
        let stringToSign = "\(timestampSeconds)\n\(secret)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(),
            using: SymmetricKey(data: Data(stringToSign.utf8))
        )
        return Data(mac).base64EncodedString()
    }

    /// `application/x-www-form-urlencoded` as Java's URLEncoder / Python's
    /// `quote_plus` produce it — the encoding DingTalk's samples use.
    public static func formURLEncoded(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "*"):
                result.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                result.append("+")
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}

// MARK: - Responses

/// What happened to one delivery, in a form the settings page can show as is.
public struct PushDeliveryResult: Equatable, Sendable {
    public var ok: Bool
    /// nil when no HTTP response arrived (DNS, TLS, timeout, ATS).
    public var statusCode: Int?
    /// Server-side reason (errcode/errmsg, code/msg, description, …) or the
    /// transport error.
    public var message: String
    /// Set when the request was answered from a different URL than it was
    /// sent to — the user should update the saved URL.
    public var redirectedTo: String?
    /// Set when the server redirected somewhere CodeIsland refuses to follow
    /// (another host, or https → http): the address to save instead, if the
    /// user trusts it. Credential-free, like `redirectedTo`.
    public var redirectRefusedTo: String?

    public init(
        ok: Bool,
        statusCode: Int?,
        message: String,
        redirectedTo: String? = nil,
        redirectRefusedTo: String? = nil
    ) {
        self.ok = ok
        self.statusCode = statusCode
        self.message = message
        self.redirectedTo = redirectedTo
        self.redirectRefusedTo = redirectRefusedTo
    }

    /// "HTTP 200 · ok", "HTTP 200 · errcode 310000: sign not match".
    public var summary: String {
        let status = statusCode.map { "HTTP \($0)" }
        return [status, message.isEmpty ? nil : message].compactMap { $0 }.joined(separator: " · ")
    }

    /// `summary` fit for the unified log, which a diagnostics export ships
    /// off the Mac: servers echo what they were sent (bark-server the device
    /// key, WeCom the caller's public IP), so this channel's own credentials
    /// and every IP address are taken out, then the usual credential shapes.
    public func loggableSummary(for channel: PushChannelConfig) -> String {
        var text = summary
        for secret in Self.secrets(of: channel) where text.contains(secret) {
            text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        for regex in Self.addressPatterns {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "[IP]"
            )
        }
        return HookEvent.sanitizedSummary(text, limit: 400) ?? ""
    }

    /// Every configured value that is, or may contain, a credential: device
    /// key / topic / chat id, tokens, secrets, and the webhook's userinfo,
    /// path segments and query values. Longest first, so a value that
    /// contains another is replaced whole.
    static func secrets(of channel: PushChannelConfig) -> [String] {
        var values = [channel.target, channel.token, channel.secret]
        if channel.token.hasPrefix("bot") { values.append(String(channel.token.dropFirst(3))) }
        if let parts = URLComponents(string: channel.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) {
            values += [parts.user, parts.password].compactMap { $0 }
            values += parts.path.split(separator: "/").map(String.init).filter { $0.count >= 8 }
            values += (parts.queryItems ?? []).compactMap(\.value)
        }
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 4 }
        return Array(Set(trimmed)).sorted { $0.count > $1.count }
    }

    private static let addressPatterns: [NSRegularExpression] = [
        #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
        #"\b(?:[0-9A-Fa-f]{1,4}:){4,7}[0-9A-Fa-f]{1,4}\b"#,
        #"\b[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

public enum PushResponseInterpreter {
    static let messageLimit = 300

    /// Most of these services answer HTTP 200 for a rejected message and put
    /// the verdict in the body, so the body decides, not the status alone.
    public static func interpret(kind: PushChannelKind, statusCode: Int, body: Data) -> (ok: Bool, message: String) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let httpOK = (200..<300).contains(statusCode)

        func fallback() -> (Bool, String) {
            (httpOK, limited(text.isEmpty ? (httpOK ? "ok" : "") : text))
        }

        switch kind {
        case .bark:
            // {"code":200,"message":"success","timestamp":…}; errors reuse the shape.
            guard let json else { return fallback() }
            let code = integer(json["code"])
            let message = json["message"] as? String ?? ""
            let ok = httpOK && (code == nil || code == 200)
            return (ok, limited(message.isEmpty ? (ok ? "ok" : text) : message))

        case .ntfy:
            // Errors: {"code":40301,"http":403,"error":"forbidden","link":…}.
            if httpOK { return (true, "ok") }
            guard let json, let error = json["error"] as? String else { return fallback() }
            let code = integer(json["code"]).map { " (\($0))" } ?? ""
            return (false, limited(error + code))

        case .dingtalk, .wecom:
            // {"errcode":0,"errmsg":"ok"}; DingTalk's docs show errcode as a string.
            guard let json, let code = integer(json["errcode"]) else { return fallback() }
            let message = json["errmsg"] as? String ?? ""
            if httpOK && code == 0 { return (true, limited(message.isEmpty ? "ok" : message)) }
            return (false, limited("errcode \(code): \(message)"))

        case .feishu:
            // {"code":0,"msg":"success"}; legacy {"StatusCode":0,"StatusMessage":…}.
            guard let json, let code = integer(json["code"]) ?? integer(json["StatusCode"]) else { return fallback() }
            let message = json["msg"] as? String ?? json["StatusMessage"] as? String ?? ""
            if httpOK && code == 0 { return (true, limited(message.isEmpty ? "ok" : message)) }
            return (false, limited("code \(code): \(message)"))

        case .slack:
            // 200 "ok"; errors are plain strings like "invalid_payload", "no_service".
            return fallback()

        case .telegram:
            // {"ok":false,"error_code":400,"description":"Bad Request: chat not found"}
            guard let json, let ok = json["ok"] as? Bool else { return fallback() }
            if ok { return (true, "ok") }
            let description = json["description"] as? String ?? text
            let code = integer(json["error_code"]).map { "\($0): " } ?? ""
            return (false, limited(code + description))
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func limited(_ text: String) -> String {
        PushMessageFormatter.truncated(text, limit: messageLimit)
    }
}
