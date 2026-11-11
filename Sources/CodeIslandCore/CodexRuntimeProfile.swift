import Foundation

/// How a Codex CLI session is authenticated and routed.
public enum CodexAccessKind: String, Codable, Equatable, Sendable {
    case officialSubscription
    case apiRouter
    case apiKey
    case unknown
}

/// Which quota source is meaningful for a Codex runtime profile.
public enum CodexQuotaCapability: String, Codable, Equatable, Sendable {
    case officialFiveHourAndWeekly
    case localUsageOnly
    case unavailable
    case unknown
}

/// Non-secret identity of the Codex runtime currently configured on this Mac.
/// Tokens and API keys are deliberately never retained in this value.
public struct CodexRuntimeProfile: Codable, Equatable, Sendable {
    public let accessKind: CodexAccessKind
    public let quotaCapability: CodexQuotaCapability
    public let modelProvider: String?
    public let endpointHost: String?
    public let authMode: String?

    public init(
        accessKind: CodexAccessKind,
        quotaCapability: CodexQuotaCapability,
        modelProvider: String? = nil,
        endpointHost: String? = nil,
        authMode: String? = nil
    ) {
        self.accessKind = accessKind
        self.quotaCapability = quotaCapability
        self.modelProvider = modelProvider
        self.endpointHost = endpointHost
        self.authMode = authMode
    }

    public static let unknown = CodexRuntimeProfile(
        accessKind: .unknown,
        quotaCapability: .unknown
    )
}

/// Reads the small subset of Codex auth/config state needed to decide whether
/// the official quota endpoint is applicable. This reader has no network or
/// process side effects and never returns credential material.
public enum CodexRuntimeProfileReader {
    public static func read(
        codexHome: String? = nil,
        fileManager: FileManager = .default
    ) -> CodexRuntimeProfile {
        let root = URL(fileURLWithPath: codexHome ?? defaultCodexHome(), isDirectory: true)
        let authData = fileManager.contents(atPath: root.appendingPathComponent("auth.json").path)
        let config = fileManager.contents(atPath: root.appendingPathComponent("config.toml").path)
            .flatMap { String(data: $0, encoding: .utf8) }
        return profile(authJSON: authData, configTOML: config)
    }

    public static func profile(authJSON: Data?, configTOML: String?) -> CodexRuntimeProfile {
        let auth = parseAuth(authJSON)
        let config = parseConfig(configTOML)
        return classify(auth: auth, config: config)
    }

    private static func defaultCodexHome() -> String {
        let raw = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return NSHomeDirectory() + "/" + raw.dropFirst(2) }
        return raw.isEmpty ? NSHomeDirectory() + "/.codex" : raw
    }

    private struct AuthSnapshot {
        let mode: String?
        let hasOAuthToken: Bool
        let hasAPIKey: Bool
    }

    private struct ConfigSnapshot {
        let modelProvider: String?
        let endpoint: String?
    }

    private static func parseAuth(_ data: Data?) -> AuthSnapshot {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AuthSnapshot(mode: nil, hasOAuthToken: false, hasAPIKey: false)
        }

        let explicitMode = (object["auth_mode"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let tokens = object["tokens"] as? [String: Any]
        let hasOAuthToken = (tokens?["access_token"] as? String)
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let hasAPIKey = (object["OPENAI_API_KEY"] as? String)
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let inferredMode = explicitMode ?? (hasOAuthToken ? "oauth" : (hasAPIKey ? "apikey" : nil))
        return AuthSnapshot(mode: inferredMode, hasOAuthToken: hasOAuthToken, hasAPIKey: hasAPIKey)
    }

    private static func parseConfig(_ text: String?) -> ConfigSnapshot {
        guard let text else { return ConfigSnapshot(modelProvider: nil, endpoint: nil) }

        var section: [String] = []
        var modelProvider: String?
        var endpoints: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = removeComment(from: String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.first == "[", line.last == "]" {
                section = splitPath(String(line.dropFirst().dropLast()))
                continue
            }

            guard let equals = firstAssignmentIndex(in: line) else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = line[line.index(after: equals)...]
            guard let value = parseScalar(rawValue) else { continue }

            if section.isEmpty, key == "model_provider" {
                modelProvider = value
            } else if section.count == 2,
                      section[0] == "model_providers",
                      key == "base_url" {
                endpoints[section[1]] = value
            }
        }

        let endpoint = modelProvider.flatMap { endpoints[$0] }
        return ConfigSnapshot(modelProvider: modelProvider, endpoint: endpoint)
    }

    private static func classify(
        auth: AuthSnapshot,
        config: ConfigSnapshot
    ) -> CodexRuntimeProfile {
        let provider = config.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = provider?.lowercased()
        let host = endpointHost(config.endpoint)
        let routerNamed = normalizedProvider.map(isRouterName) ?? false
        let customEndpoint = host.map { !officialHosts.contains($0) } ?? false
        let isRouter = routerNamed || customEndpoint

        let accessKind: CodexAccessKind
        if isRouter {
            accessKind = .apiRouter
        } else if auth.mode == "apikey" || auth.hasAPIKey {
            accessKind = .apiKey
        } else if auth.hasOAuthToken, auth.mode != "apikey" {
            accessKind = .officialSubscription
        } else {
            accessKind = .unknown
        }

        let capability: CodexQuotaCapability
        switch accessKind {
        case .officialSubscription:
            capability = .officialFiveHourAndWeekly
        case .apiRouter, .apiKey:
            capability = .localUsageOnly
        case .unknown:
            capability = .unknown
        }

        return CodexRuntimeProfile(
            accessKind: accessKind,
            quotaCapability: capability,
            modelProvider: provider,
            endpointHost: host,
            authMode: auth.mode
        )
    }

    private static let officialHosts: Set<String> = [
        "api.openai.com",
        "chatgpt.com",
        "chat.openai.com",
        "platform.openai.com",
        "api.chatgpt.com",
    ]

    private static func isRouterName(_ value: String) -> Bool {
        ["router", "proxy", "gateway", "relay"].contains { value.contains($0) }
    }

    private static func endpointHost(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if !value.contains("://") { value = "https://" + value }
        return URL(string: value)?.host?.lowercased()
    }

    private static func firstAssignmentIndex(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "\\" && quote == "\"" {
                escaped.toggle()
                continue
            }
            if (character == "\"" || character == "'") && !escaped {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            }
            if character == "=", quote == nil { return index }
            escaped = false
        }
        return nil
    }

    private static func removeComment(from line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "\\" && quote == "\"" {
                escaped.toggle()
                continue
            }
            if (character == "\"" || character == "'") && !escaped {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            }
            if character == "#", quote == nil { return String(line[..<index]) }
            escaped = false
        }
        return line
    }

    private static func parseScalar(_ raw: Substring) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.first == "\"", value.last == "\"" {
            let data = Data(value.utf8)
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
        }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value.split(whereSeparator: { $0.isWhitespace || $0 == "#" }).first.map(String.init)
    }

    private static func splitPath(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in raw {
            if let activeQuote = quote {
                if character == "\\" && activeQuote == "\"" {
                    escaped.toggle()
                    current.append(character)
                    continue
                }
                if character == activeQuote, !escaped {
                    selfAppendTrimmed(&current, to: &result)
                    quote = nil
                } else {
                    current.append(character)
                }
                escaped = false
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                selfAppendTrimmed(&current, to: &result)
            } else {
                current.append(character)
            }
        }
        selfAppendTrimmed(&current, to: &result)
        return result
    }

    private static func selfAppendTrimmed(_ current: inout String, to result: inout [String]) {
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { result.append(value) }
        current.removeAll(keepingCapacity: true)
    }
}
