import Foundation

/// Claude Desktop "Cowork" (local agent mode) sessions run the Claude Code
/// engine inside a sandbox VM, so `~/.claude/settings.json` hooks never fire
/// for them (anthropics/claude-code#40495). What the host *can* read is Claude
/// Desktop's own session store, one directory per account/org pair:
///
///     ~/Library/Application Support/Claude/local-agent-mode-sessions/
///         <account>/<org>/local_<id>.json          session metadata (title, cwd, archived…)
///         <account>/<org>/local_<id>/audit.jsonl   every SDK message + permission card
///         <account>/<org>/local_<id>/.claude/projects/<slug>/<cliSessionId>.jsonl
///                                                  standard Claude Code transcript
///
/// Local "Chat" sessions (`sessionType: "chat"`) live in the same store with the
/// same shape. Everything here is read-only — CodeIsland never writes below
/// this root.
public enum CoworkPaths {
    public static let rootDirectoryName = "local-agent-mode-sessions"
    public static let auditFileName = "audit.jsonl"
    public static let sessionIdPrefix = "local_"
    /// Sibling of the account dirs holding plugin manifests, not sessions.
    static let skillsPluginDirectoryName = "skills-plugin"

    /// `~/Library/Application Support/Claude` — Claude Desktop's userData dir.
    public static func claudeSupportDirectory(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/Claude")
    }

    public static func defaultRoot(home: String = NSHomeDirectory()) -> String {
        (claudeSupportDirectory(home: home) as NSString).appendingPathComponent(rootDirectoryName)
    }

    public enum Kind: Equatable, Sendable {
        case metadata
        case audit
        case transcript
    }

    /// A store path this module cares about, reduced to the session it belongs to.
    public struct Classified: Equatable, Sendable {
        public let kind: Kind
        public let sessionId: String
        /// `<root>/<account>/<org>` — where `local_<id>.json` lives.
        public let accountDirectory: String
    }

    /// Mirrors the id shape Claude Desktop itself validates before routing a
    /// `local_…` id (`/^local_[A-Za-z0-9-]{1,64}$/`), widened to `_` for its
    /// `local_ditto_…` variants. Also what keeps a crafted file name from
    /// smuggling path or URL syntax into a deep link.
    public static func isValidSessionId(_ id: String) -> Bool {
        guard id.hasPrefix(sessionIdPrefix) else { return false }
        let body = id.dropFirst(sessionIdPrefix.count)
        guard !body.isEmpty, body.count <= 128 else { return false }
        return body.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": return true
            default: return false
            }
        }
    }

    /// Classify an FSEvents path. Only three shapes matter:
    ///
    ///     <a>/<b>/local_<id>.json
    ///     <a>/<b>/local_<id>/audit.jsonl
    ///     <a>/<b>/local_<id>/.claude/projects/<slug>/<name>.jsonl
    ///
    /// Everything else — debug logs, statsig caches, subagent transcripts,
    /// uploads, the `skills-plugin` tree, `agent`-type sessions one level
    /// deeper — returns nil, which is what keeps the watcher's per-event cost a
    /// string split while a Cowork turn streams.
    public static func classify(path: String, root: String) -> Classified? {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(normalizedRoot + "/") else { return nil }
        let relative = path.dropFirst(normalizedRoot.count + 1)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let account = String(parts[0])
        guard account != skillsPluginDirectoryName else { return nil }
        let accountDirectory = "\(normalizedRoot)/\(account)/\(parts[1])"
        let leaf = String(parts[2])

        if parts.count == 3 {
            guard leaf.hasSuffix(".json") else { return nil }
            let id = String(leaf.dropLast(".json".count))
            guard isValidSessionId(id) else { return nil }
            return Classified(kind: .metadata, sessionId: id, accountDirectory: accountDirectory)
        }

        guard isValidSessionId(leaf) else { return nil }
        if parts.count == 4, parts[3] == auditFileName {
            return Classified(kind: .audit, sessionId: leaf, accountDirectory: accountDirectory)
        }
        if parts.count == 7, parts[3] == ".claude", parts[4] == "projects", parts[6].hasSuffix(".jsonl") {
            return Classified(kind: .transcript, sessionId: leaf, accountDirectory: accountDirectory)
        }
        return nil
    }

    public static func metadataPath(accountDirectory: String, sessionId: String) -> String {
        "\(accountDirectory)/\(sessionId).json"
    }

    public static func sessionDirectory(accountDirectory: String, sessionId: String) -> String {
        "\(accountDirectory)/\(sessionId)"
    }

    public static func auditPath(accountDirectory: String, sessionId: String) -> String {
        "\(sessionDirectory(accountDirectory: accountDirectory, sessionId: sessionId))/\(auditFileName)"
    }

    /// Resolve the host path of a session's CLI transcript the same way Claude
    /// Desktop does: the project slug is derived from the in-VM cwd, so scan
    /// `.claude/projects/*/` for `<cliSessionId>.jsonl` instead of re-deriving it.
    public static func transcriptPath(
        sessionDirectory: String,
        cliSessionId: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard !cliSessionId.isEmpty, !cliSessionId.contains("/") else { return nil }
        let projects = "\(sessionDirectory)/.claude/projects"
        guard let slugs = try? fileManager.contentsOfDirectory(atPath: projects) else { return nil }
        for slug in slugs.sorted() where !slug.hasPrefix(".") {
            let candidate = "\(projects)/\(slug)/\(cliSessionId).jsonl"
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Decoded `local_<id>.json`. Only the fields the island shows or filters on.
public struct CoworkSessionMetadata: Equatable, Sendable {
    public var sessionId: String
    public var cliSessionId: String?
    public var title: String?
    public var initialMessage: String?
    /// In-VM working directory (`/sessions/<processName>`) for sandboxed runs.
    public var cwd: String?
    /// Host folders the user granted — the only host-side "project" a Cowork task has.
    public var userSelectedFolders: [String]
    public var model: String?
    public var createdAt: Date?
    public var lastActivityAt: Date?
    public var isArchived: Bool
    /// nil for a regular Cowork task; `chat`, `scheduled`, `agent`, `dispatch_child`, `radar`, …
    public var sessionType: String?

    public init(
        sessionId: String,
        cliSessionId: String? = nil,
        title: String? = nil,
        initialMessage: String? = nil,
        cwd: String? = nil,
        userSelectedFolders: [String] = [],
        model: String? = nil,
        createdAt: Date? = nil,
        lastActivityAt: Date? = nil,
        isArchived: Bool = false,
        sessionType: String? = nil
    ) {
        self.sessionId = sessionId
        self.cliSessionId = cliSessionId
        self.title = title
        self.initialMessage = initialMessage
        self.cwd = cwd
        self.userSelectedFolders = userSelectedFolders
        self.model = model
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.isArchived = isArchived
        self.sessionType = sessionType
    }

    /// Parse one metadata file. Returns nil unless it carries a valid `local_` id —
    /// a half-written or foreign JSON must never become a card.
    public static func parse(_ data: Data) -> CoworkSessionMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["sessionId"] as? String,
              CoworkPaths.isValidSessionId(sessionId) else {
            return nil
        }
        return CoworkSessionMetadata(
            sessionId: sessionId,
            cliSessionId: nonEmpty(json["cliSessionId"]),
            title: nonEmpty(json["title"]),
            initialMessage: nonEmpty(json["initialMessage"]),
            cwd: nonEmpty(json["cwd"]),
            userSelectedFolders: (json["userSelectedFolders"] as? [Any])?
                .compactMap { nonEmpty($0) } ?? [],
            model: nonEmpty(json["model"]),
            createdAt: epochMilliseconds(json["createdAt"]),
            lastActivityAt: epochMilliseconds(json["lastActivityAt"]),
            isArchived: (json["isArchived"] as? Bool) ?? false,
            sessionType: nonEmpty(json["sessionType"])
        )
    }

    /// Host path to show as the card's project. The sandboxed cwd
    /// (`/sessions/<vm-name>`) means nothing on the Mac, so the first folder the
    /// user granted wins; a host-loop session's real cwd is the fallback.
    public var hostCwd: String? {
        if let folder = userSelectedFolders.first(where: { $0.hasPrefix("/") }) {
            return folder
        }
        guard let cwd, cwd.hasPrefix("/"), !cwd.hasPrefix("/sessions/") else { return nil }
        return cwd
    }

    /// Card title: Claude Desktop's generated title, else the opening prompt.
    public var displayTitle: String? {
        if let title { return title }
        guard let initialMessage else { return nil }
        let singleLine = initialMessage
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return nil }
        return singleLine.count > 80 ? String(singleLine.prefix(80)) + "…" : singleLine
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Claude Desktop stores `Date.now()` — epoch milliseconds.
    private static func epochMilliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let ms = number.doubleValue
        guard ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// The rules for which store sessions deserve a card. Pure so the ghost-card
/// guarantees are pinned by tests rather than by the watcher's timing.
public enum CoworkSessionPolicy {
    /// A session whose last activity is older than this gets no card on
    /// CodeIsland launch. Matches the idle sweep's 10-minute no-monitor window,
    /// so a restart never shows anything the sweep would already have removed.
    public static let launchFreshness: TimeInterval = 10 * 60

    /// Session types Claude Desktop itself hides from its sidebar: the
    /// background Dispatch agent, the tasks it spawns, and proactive "radar" runs.
    public static let hiddenSessionTypes: Set<String> = ["agent", "dispatch_child", "radar"]

    public static func isHidden(sessionType: String?) -> Bool {
        guard let sessionType else { return false }
        return hiddenSessionTypes.contains(sessionType)
    }

    /// May this session hold a card at all (independent of recency)?
    public static func isTrackable(_ metadata: CoworkSessionMetadata) -> Bool {
        !metadata.isArchived && !isHidden(sessionType: metadata.sessionType)
    }

    /// Most recent evidence of activity: the persisted `lastActivityAt` is only
    /// saved on some state changes, while the audit log is appended on every SDK
    /// message — take whichever is newer.
    public static func lastActivity(metadata: CoworkSessionMetadata, auditModifiedAt: Date?) -> Date? {
        switch (metadata.lastActivityAt, auditModifiedAt) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Launch-time gate. A card is only rebuilt from history when the session
    /// is trackable, has had at least one turn (a non-empty audit log), and was
    /// active within `launchFreshness`. Everything else stays history — this is
    /// what keeps a CodeIsland restart from resurrecting long-finished Cowork
    /// tasks as ghost cards.
    public static func shouldSurfaceOnLaunch(
        metadata: CoworkSessionMetadata,
        auditSize: UInt64,
        lastActivity: Date?,
        now: Date,
        freshness: TimeInterval = launchFreshness
    ) -> Bool {
        guard isTrackable(metadata), auditSize > 0, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) <= freshness
    }

    /// The same conversation already has a hook-driven card. Cowork hooks are
    /// broken today (#40495) but if Anthropic fixes them, hook events arrive
    /// keyed by the CLI session id — that card is richer (approvals, tools), so
    /// the file-derived one steps aside.
    public static func isShadowedByHookSession(
        cliSessionId: String?,
        existingSessionKeys: Set<String>
    ) -> Bool {
        guard let cliSessionId, !cliSessionId.isEmpty else { return false }
        return existingSessionKeys.contains(cliSessionId)
    }

    /// `claude://claude.ai/cowork/<id>` — Claude Desktop routes this host+path
    /// to the in-app `/cowork/<id>` screen (the same route its own permission
    /// and "task finished" notifications navigate to). Nil for anything that is
    /// not a well-formed store id, so a click never opens a guessed URL.
    public static func deepLinkURL(sessionId: String) -> URL? {
        guard CoworkPaths.isValidSessionId(sessionId) else { return nil }
        return URL(string: "claude://claude.ai/cowork/\(sessionId)")
    }
}
