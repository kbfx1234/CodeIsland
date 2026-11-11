import Foundation

/// A child session and the card it works for: the one internal answer to
/// "whose card is this hook's", whichever agent the child comes from.
///
/// Agents spawn sessions of their own: a Codex subagent thread, a Cursor
/// Agent Task, a pi-subagents child, a plugin firing another agent's hooks
/// (omo in OpenCode). Each kind's resolver reads its own evidence (a declared
/// parent, a transcript path, a rollout's `session_meta`, a shared process)
/// and produces a link; ``SubsessionRouter`` then applies Agent Sub-Sessions
/// to every kind the same way. A new integration plugs in by producing a link.
///
/// Claude Code's own subagents (`agent_id` on the parent's hooks) are not
/// links: the agent already files them under its session.
public struct SubsessionLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The child named its parent (`_parent_session_id`, #378).
        case declared
        /// A Cursor Agent Task: its transcript path names the chat it runs
        /// for, or it shares that chat's IDE process.
        case cursorTask = "cursor"
        /// A Codex subagent thread: its rollout's `session_meta` names the
        /// parent thread, it shares the parent's CLI process, or Codex filed
        /// its hook under the parent itself.
        case codexThread = "codex"
        /// Another agent firing this agent's hooks (`_via_plugin`, #123).
        case pluginProxy = "plugin"

        /// The subagent row label for a folded child whose hook names no
        /// `agent_type`.
        public var defaultAgentType: String {
            switch self {
            case .declared: return "subagent"
            case .cursorTask: return "cursor-subagent"
            case .codexThread: return "default"
            case .pluginProxy: return "subagent"
            }
        }

        /// Whether every hook of such a child says it is one
        /// (`_parent_session_id`, `_via_plugin`), so any card of its own is
        /// one the router left it on. A Codex thread's rollout or a Cursor
        /// Task's IDE process can name a parent only after the child's first
        /// hooks built a card that is nobody's child.
        public var isAnnouncedByEveryHook: Bool {
            switch self {
            case .declared, .pluginProxy: return true
            case .cursorTask, .codexThread: return false
            }
        }

        /// Whether Merge may fold the child into a parent card the island
        /// does not show yet, which the fold then creates. Only a Cursor
        /// transcript names the parent conversation's own session id, so the
        /// card it would create is the one the parent's hooks land on; for
        /// every other kind an unknown parent is not invented.
        public var mayCreateParentCard: Bool {
            self == .cursorTask
        }
    }

    public let kind: Kind
    /// The card the child's own hooks file under (``HookEvent/sessionId``).
    public let childCardId: String
    /// The id the child goes by as a subagent row of the card it is folded
    /// into.
    public let agentId: String
    /// The card the child works for, by key; it may not exist (yet). nil
    /// when the evidence says the hook is a child's without naming whose
    /// (a plugin proxy with no card of its agent on the island).
    public let parentCardId: String?
    /// The id the parent goes by as a subagent row, for a parent that is a
    /// child itself: Merge folds a grandchild into the card its parent is
    /// folded into.
    public let parentAgentId: String?
    /// The subagent row label the evidence offers; the hook's own
    /// `agent_type` wins, and ``Kind/defaultAgentType`` stands in for both.
    public let agentType: String?
    /// The parent is a guess from a process the two share, not something the
    /// child or its transcript said. Merge and Hide act on such a guess, as
    /// they always have; Show separately does not, since it is the default
    /// and a wrong guess would silence a session the user started.
    public let isInferred: Bool
    /// The agent itself filed the hook under the parent's session
    /// (``parentCardId``) rather than the child's own: it already sits where
    /// Merge would put it. Codex's own subagent hooks name the child there,
    /// as their `agent_id`; one that does not is ``isFiledAsParentsOwn``.
    public let isProviderFolded: Bool
    /// With ``isProviderFolded``: the hook names no child (no `agent_id`;
    /// Codex has filed a thread it does not report as a subagent that way),
    /// so as it came it is the parent's own event — the child's Stop would
    /// end the parent's turn. The router names it ``agentId`` where it sits.
    public let isFiledAsParentsOwn: Bool

    public init(
        kind: Kind,
        childCardId: String,
        agentId: String,
        parentCardId: String?,
        parentAgentId: String? = nil,
        agentType: String? = nil,
        isInferred: Bool = false,
        isProviderFolded: Bool = false,
        isFiledAsParentsOwn: Bool = false
    ) {
        self.kind = kind
        self.childCardId = childCardId
        self.agentId = agentId
        self.parentCardId = parentCardId
        self.parentAgentId = parentAgentId
        self.agentType = agentType
        self.isInferred = isInferred
        self.isProviderFolded = isProviderFolded
        self.isFiledAsParentsOwn = isFiledAsParentsOwn
    }
}

/// The Agent Sub-Sessions setting (`pluginSessionMode`).
public enum SubsessionMode: String, Sendable {
    /// A child keeps a card of its own, linked to its parent: quiet, since
    /// its turns are the parent's business.
    case separate
    /// A child folds into its parent's card as a subagent.
    case merge
    /// A child is not shown; a request it is blocked on still surfaces.
    case hide

    /// An unknown setting reads as Show separately, the default.
    public init(setting: String?) {
        self = setting.flatMap(SubsessionMode.init(rawValue:)) ?? .separate
    }
}

/// What the resolvers and the router need to know about the island. AppState
/// answers it in the app; tests hand in a stub, so every resolver runs
/// without one.
public protocol SubsessionContext {
    /// The cards on the island, by key (`AppState.sessions`).
    var cards: [String: SessionSnapshot] { get }
    /// What the Codex rollout at `transcriptPath` says (`session_meta`) about
    /// its thread's parent. The app reads each rollout once
    /// (``CodexRolloutCache``): this runs for every Codex hook.
    func codexRolloutInspection(transcriptPath: String) -> CodexTranscriptSubagentInspection
}

/// Lookups over the island's cards that resolving a child's parent needs.
public enum SubsessionCards {
    /// A card whose CLI process has not shown activity for this long may be
    /// a dead session whose PID the OS has since handed to another process.
    public static let samePidActivityWindow: TimeInterval = 300

    /// The card filed under `providerSessionId`: its own key, its Codex
    /// Desktop key, or a card that records it as its provider session id.
    public static func cardId(
        forProviderSessionId providerSessionId: String,
        in cards: [String: SessionSnapshot]
    ) -> String? {
        if cards[providerSessionId] != nil {
            return providerSessionId
        }
        let codexAppId = "codexapp:" + providerSessionId
        if cards[codexAppId] != nil {
            return codexAppId
        }
        return cards.first(where: { _, snap in
            snap.providerSessionId == providerSessionId
        })?.key
    }

    /// A card whose source matches and whose CLI PID is `ppid`, on the
    /// machine the hook came from (`remoteHostId`, nil for this Mac): the
    /// session a plugin proxy's or a Codex thread's process belongs to (#123).
    /// A process id means nothing on another host.
    ///
    /// The candidate must have been active in the last five minutes. This
    /// guards against macOS PID reuse — a stale session whose CLI long since
    /// exited could otherwise still match the hook's `_ppid` if the OS
    /// recycled that PID for an unrelated process. Live sessions update
    /// `lastActivity` on every event so the window is generous; stale ones
    /// get skipped. (#123 review)
    public static func samePidCard(
        source: String,
        ppid: Int,
        remoteHostId: String?,
        excluding excludedCardId: String? = nil,
        requireActive: Bool = false,
        in cards: [String: SessionSnapshot],
        now: Date = Date()
    ) -> String? {
        // Past pid_t's range it names no process; converting it would trap.
        guard let pid = pid_t(exactly: ppid) else { return nil }
        let normalized = SessionSnapshot.normalizedSupportedSource(source)
        let cutoff = now.addingTimeInterval(-samePidActivityWindow)
        return cards
            .filter { cardId, snap in
                let snapSource = SessionSnapshot.normalizedSupportedSource(snap.source)
                return snapSource == normalized
                    && snap.processId(onHost: remoteHostId) == pid
                    && isCard(cardId, onHost: remoteHostId)
                    && snap.lastActivity >= cutoff
                    && cardId != excludedCardId
                    && (!requireActive || snap.status != .idle)
            }
            .sorted { lhs, rhs in
                let lhsActive = lhs.value.status != .idle
                let rhsActive = rhs.value.status != .idle
                if lhsActive != rhsActive { return lhsActive }
                return lhs.value.startTime < rhs.value.startTime
            }
            .first?.key
    }

    /// Whether the card is a session of the machine a hook from
    /// `remoteHostId` came from (nil: this Mac). A remote session's card is
    /// filed under its host (``HookEvent/cardSessionId(forRawSessionId:in:)``).
    public static func isCard(_ cardId: String, onHost remoteHostId: String?) -> Bool {
        guard let remoteHostId else { return !cardId.hasPrefix("remote:") }
        return cardId.hasPrefix("remote:\(remoteHostId):")
    }

    /// A Codex parent in the same Desktop/CLI namespace as its child. Raw
    /// and `codexapp:` cards may legitimately share a provider thread id
    /// when a user resumes the same thread in both surfaces.
    public static func codexParentCard(
        threadId: String,
        childTermBundleId: String?,
        in cards: [String: SessionSnapshot]
    ) -> String? {
        let childIsDesktop = childTermBundleId == "com.openai.codex"
        let canonicalId = childIsDesktop ? "codexapp:" + threadId : threadId
        if let session = cards[canonicalId],
           session.source == "codex",
           session.isNativeAppMode == childIsDesktop {
            return canonicalId
        }
        return cards.first(where: { _, snapshot in
            snapshot.source == "codex"
                && snapshot.providerSessionId == threadId
                && snapshot.isNativeAppMode == childIsDesktop
        })?.key
    }

    /// The card a child session with this subagent id is folded into, if
    /// any. Only rows that are child sessions count (``SubagentState/subsessionKind``):
    /// a Codex parent's own SubagentStart row for a thread whose hooks keep a
    /// card of their own must not pull that thread off it.
    public static func cardHosting(
        foldedSubsession agentId: String,
        in cards: [String: SessionSnapshot]
    ) -> String? {
        cards.first { $0.value.subagents[agentId]?.subsessionKind != nil }?.key
    }

    /// The card with a subagent row of this id, whoever made it: Codex files
    /// a spawned thread's hooks as a row of the session that spawned it.
    public static func cardHosting(
        subagent agentId: String,
        in cards: [String: SessionSnapshot]
    ) -> String? {
        cards.first { $0.value.subagents[agentId] != nil }?.key
    }
}
