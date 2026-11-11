import Foundation

/// Maps Cursor Task/subagent hooks onto their parent chat card.
///
/// Child hooks use a different `session_id`, but `transcript_path` still points at
/// `…/agent-transcripts/<parentId>/…`. Without rewriting, each Task appears as a
/// duplicate Cursor card for the same IDE conversation.
public enum CursorSessionFolding {
    /// UUID segment under `agent-transcripts/`.
    private static let uuidDirPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    /// True when `path` is under Cursor's `agent-transcripts` tree
    /// (`~/.cursor/projects/…/agent-transcripts/…`).
    public static func isCursorAgentTranscriptPath(_ path: String?) -> Bool {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return false
        }
        guard path.contains("/agent-transcripts/") else { return false }
        return path.contains("/.cursor/") || path.contains("/cursor/projects/")
    }

    /// Parent conversation id from a Cursor `transcript_path`, when present.
    ///
    /// Recognized layouts:
    /// - `…/agent-transcripts/<parentId>/<parentId>.jsonl`
    /// - `…/agent-transcripts/<parentId>/subagents/<childId>.jsonl`
    public static func parentConversationId(fromTranscriptPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = (trimmed as NSString).pathComponents
        guard let transcriptsIdx = parts.lastIndex(of: "agent-transcripts"),
              transcriptsIdx + 1 < parts.count else {
            return nil
        }

        let parentCandidate = parts[transcriptsIdx + 1]
        guard parentCandidate.range(of: uuidDirPattern, options: .regularExpression) != nil else {
            return nil
        }
        return parentCandidate
    }

    /// Parent id when `childSessionId` is a Task of that conversation
    /// (`transcript_path` parent ≠ `childSessionId`).
    public static func foldTarget(childSessionId: String, transcriptPath: String?) -> String? {
        let child = childSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !child.isEmpty,
              let path = transcriptPath,
              let parentId = parentConversationId(fromTranscriptPath: path),
              parentId != child else {
            return nil
        }
        return parentId
    }
}

/// Cursor's half of Agent Sub-Sessions: the chat a Cursor Agent Task works
/// for (``SubsessionLink``), and what tells a Task card from a chat.
public enum CursorSubsessionRouter {
    /// `cursor` / `cursor-cli` after normalization.
    public static func isCursorFamilySource(_ source: String?) -> Bool {
        let normalized = SessionSnapshot.normalizedSupportedSource(source)
        return normalized == "cursor" || normalized == "cursor-cli"
    }

    /// Treat as Cursor Task routing even when `_source` is missing or still the
    /// default `"claude"` — Cursor Agent Tasks often fire Claude-format hooks
    /// without `--source`, which would otherwise leave a ghost Claude card.
    public static func shouldTreatAsCursorFamily(
        declaredSource: String?,
        transcriptPath: String?
    ) -> Bool {
        if isCursorFamilySource(declaredSource) { return true }
        guard CursorSessionFolding.isCursorAgentTranscriptPath(transcriptPath) else {
            return false
        }
        let normalized = SessionSnapshot.normalizedSupportedSource(declaredSource)
        return normalized == nil || normalized == "claude"
    }

    /// The chat this Cursor hook's session is a Task of.
    ///
    /// The transcript path names it (`agent-transcripts/<chat>/…` under a
    /// session id other than the chat's). A Task's own hooks carry no
    /// transcript path — Cursor resolves one only for a top-level
    /// conversation — so for those the chat is the one card left on the same
    /// IDE process: a guess (``SubsessionLink/isInferred``), made only for a
    /// session with no card of its own yet.
    public static func link(
        in raw: [String: Any],
        context: SubsessionContext,
        now: Date = Date()
    ) -> SubsessionLink? {
        let declared = (raw["_source"] as? String) ?? (raw["source"] as? String)
        let path = SubsessionRouter.transcriptPath(in: raw)
        guard shouldTreatAsCursorFamily(declaredSource: declared, transcriptPath: path),
              let childSessionId = SubsessionRouter.sessionId(in: raw) else {
            return nil
        }
        let childCardId = HookEvent.cardSessionId(forRawSessionId: childSessionId, in: raw)

        if let parentId = CursorSessionFolding.foldTarget(
            childSessionId: childSessionId,
            transcriptPath: path
        ) {
            // Transcript parent UUID may differ from the AppState session key.
            // A Task card that reused the parent's id as its provider session
            // id is not the parent.
            let parentKey = HookEvent.cardSessionId(forRawSessionId: parentId, in: raw)
            let found = SubsessionCards.cardId(forProviderSessionId: parentId, in: context.cards)
            return SubsessionLink(
                kind: .cursorTask,
                childCardId: childCardId,
                agentId: childSessionId,
                parentCardId: found.flatMap { $0 == childCardId ? nil : $0 } ?? parentKey
            )
        }

        guard shouldAttemptPpidParentFallback(raw: raw),
              // Established top-level card for this session_id = main chat continuing.
              // Never `_ppid`-fold it onto a sibling Task (that freezes parent chat text).
              !cursorSessionCardExists(for: childSessionId, in: context.cards),
              let parentCardId = ppidParentCardId(in: raw, cards: context.cards, now: now) else {
            return nil
        }
        return SubsessionLink(
            kind: .cursorTask,
            childCardId: childCardId,
            agentId: childSessionId,
            parentCardId: parentCardId,
            isInferred: true
        )
    }

    /// Whether a parent may be resolved via `_ppid` when the transcript path
    /// names none.
    ///
    /// True with Cursor family (including misbranded Claude-default + Cursor
    /// transcript path) + session id + positive `_ppid` and **no** parseable
    /// parent UUID in `transcript_path`.
    ///
    /// Never for `sessionStart` / `sessionEnd`: Cursor sends those for a
    /// composer conversation, not a Task, and a new chat's `sessionStart`
    /// comes before Cursor has a transcript for it — a lone sibling chat on
    /// the same IDE pid would adopt the new chat as its Task.
    public static func shouldAttemptPpidParentFallback(raw: [String: Any]) -> Bool {
        let declared = (raw["_source"] as? String) ?? (raw["source"] as? String)
        let path = SubsessionRouter.transcriptPath(in: raw)
        guard shouldTreatAsCursorFamily(declaredSource: declared, transcriptPath: path),
              SubsessionRouter.sessionId(in: raw) != nil,
              SubsessionRouter.positivePpid(in: raw) != nil,
              !isConversationLifecycleEvent(raw) else {
            return false
        }
        if let path,
           CursorSessionFolding.parentConversationId(fromTranscriptPath: path) != nil {
            return false
        }
        return true
    }

    /// Search order for same-IDE parent lookup: event source first, then sibling.
    public static func parentSourceSearchOrder(primarySource: String) -> [String] {
        let normalized = SessionSnapshot.normalizedSupportedSource(primarySource) ?? primarySource
        return normalized == "cursor-cli" ? ["cursor-cli", "cursor"] : ["cursor", "cursor-cli"]
    }

    /// True when this top-level card is a foldable Cursor Task (transcript parent ≠ id).
    public static func isLikelyCursorTaskCard(
        sessionId: String,
        providerSessionId: String?,
        transcriptPath: String?
    ) -> Bool {
        if CursorSessionFolding.foldTarget(
            childSessionId: sessionId,
            transcriptPath: transcriptPath
        ) != nil {
            return true
        }
        if let providerSessionId,
           providerSessionId != sessionId,
           CursorSessionFolding.foldTarget(
               childSessionId: providerSessionId,
               transcriptPath: transcriptPath
           ) != nil {
            return true
        }
        return false
    }

    /// True when the card looks like a main Cursor chat (owns its transcript dir,
    /// or already parents live/folded Tasks).
    public static func isLikelyCursorMainCard(
        sessionId: String,
        providerSessionId: String?,
        transcriptPath: String?,
        hasSubagents: Bool
    ) -> Bool {
        if hasSubagents { return true }
        let identities = [sessionId, providerSessionId].compactMap { id -> String? in
            guard let id else { return nil }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let path = transcriptPath,
              let parentId = CursorSessionFolding.parentConversationId(fromTranscriptPath: path)
        else {
            return false
        }
        return identities.contains(parentId)
    }

    /// Pick a unique `_ppid` parent among same-PID Cursor cards.
    ///
    /// - Excludes foldable Task cards (never parent onto an orphan Task).
    /// - Prefers main-looking cards (self transcript / already has subagents).
    /// - Allows a unique idle main when it shares the IDE pid (main often goes
    ///   idle while a Task is still running).
    /// - 2+ live non-Task chats → ambiguous (`nil`).
    public static func choosePpidFallbackParentId(
        candidates: [(sessionId: String, status: AgentStatus, startTime: Date, isMain: Bool, isTask: Bool)]
    ) -> String? {
        let eligible = candidates.filter { !$0.isTask }
        guard !eligible.isEmpty else { return nil }

        let mains = eligible.filter(\.isMain)
        let pool = mains.isEmpty ? eligible : mains
        if pool.count == 1 { return pool[0].sessionId }

        let active = pool.filter { $0.status != .idle }
        let idle = pool.filter { $0.status == .idle }

        // Two+ live chats on the same IDE process — do not guess.
        if active.count >= 2 { return nil }
        if active.count == 1 {
            // Idle leftovers + one live card: prefer unique main among idle+active,
            // else the older idle card when it predates the live orphan Task.
            if idle.isEmpty { return active[0].sessionId }
            if let mainIdle = idle.first(where: \.isMain), idle.filter(\.isMain).count == 1 {
                return mainIdle.sessionId
            }
            if let oldestIdle = idle.min(by: { $0.startTime < $1.startTime }),
               oldestIdle.startTime < active[0].startTime {
                return oldestIdle.sessionId
            }
            return active[0].sessionId
        }

        // All idle: unique oldest only when startTimes differ.
        let sorted = pool.sorted { $0.startTime < $1.startTime }
        guard sorted.count >= 2, sorted[0].startTime < sorted[1].startTime else {
            return nil
        }
        return sorted[0].sessionId
    }

    /// Resolve the parent via `_ppid` when the transcript path names none.
    /// Only call when ``shouldAttemptPpidParentFallback(raw:)`` is true.
    ///
    /// Requires a **unique** active same-PID Cursor card for the preferred source
    /// (then sibling). If two chats share the IDE process, guessing is unsafe —
    /// leave the Task separate until `transcript_path` can fold it.
    static func ppidParentCardId(
        in raw: [String: Any],
        cards: [String: SessionSnapshot],
        now: Date
    ) -> String? {
        guard let source = SessionSnapshot.normalizedSupportedSource(raw["_source"] as? String),
              isCursorFamilySource(source),
              let childSessionId = SubsessionRouter.sessionId(in: raw),
              let ppid = SubsessionRouter.positivePpid(in: raw) else {
            return nil
        }
        let cutoff = now.addingTimeInterval(-SubsessionCards.samePidActivityWindow)
        for src in parentSourceSearchOrder(primarySource: source) {
            if let match = uniqueActiveSamePidCursorSession(
                source: src,
                ppid: ppid,
                remoteHostId: SubsessionRouter.remoteHostId(in: raw),
                excluding: childSessionId,
                activeSince: cutoff,
                in: cards
            ) {
                return match
            }
        }
        return nil
    }

    /// Sole suitable same-PID session for `source`, or `nil` when zero / ambiguous.
    /// Prefers main chats over orphan Task cards; idle mains remain eligible.
    private static func uniqueActiveSamePidCursorSession(
        source: String,
        ppid: Int,
        remoteHostId: String?,
        excluding excludedSessionId: String,
        activeSince cutoff: Date,
        in cards: [String: SessionSnapshot]
    ) -> String? {
        guard let pid = pid_t(exactly: ppid) else { return nil }
        let normalized = SessionSnapshot.normalizedSupportedSource(source)
        let candidates: [(sessionId: String, status: AgentStatus, startTime: Date, isMain: Bool, isTask: Bool)] =
            cards.compactMap { sessionId, snap in
                let snapSource = SessionSnapshot.normalizedSupportedSource(snap.source)
                guard snapSource == normalized,
                      snap.processId(onHost: remoteHostId) == pid,
                      SubsessionCards.isCard(sessionId, onHost: remoteHostId),
                      sessionId != excludedSessionId else {
                    return nil
                }
                // Recent activity, or idle with live IDE pid (main often idles while
                // a Task keeps the process busy).
                guard snap.lastActivity >= cutoff || snap.status == .idle else {
                    return nil
                }
                let isTask = isLikelyCursorTaskCard(
                    sessionId: sessionId,
                    providerSessionId: snap.providerSessionId,
                    transcriptPath: snap.transcriptPath
                )
                let isMain = isLikelyCursorMainCard(
                    sessionId: sessionId,
                    providerSessionId: snap.providerSessionId,
                    transcriptPath: snap.transcriptPath,
                    hasSubagents: !snap.subagents.isEmpty
                )
                return (sessionId, snap.status, snap.startTime, isMain, isTask)
            }
        return choosePpidFallbackParentId(candidates: candidates)
    }

    /// True when `sessionId` already names a top-level Cursor card (exact key
    /// or `providerSessionId` match).
    static func cursorSessionCardExists(for sessionId: String, in cards: [String: SessionSnapshot]) -> Bool {
        if let snap = cards[sessionId], isCursorFamilySource(snap.source) {
            return true
        }
        if let key = SubsessionCards.cardId(forProviderSessionId: sessionId, in: cards),
           let snap = cards[key],
           isCursorFamilySource(snap.source) {
            return true
        }
        return false
    }

    private static func isConversationLifecycleEvent(_ raw: [String: Any]) -> Bool {
        guard let name = SubsessionRouter.nonEmptyString(raw["hook_event_name"])
                ?? SubsessionRouter.nonEmptyString(raw["hookEventName"]) else {
            return false
        }
        let normalized = EventNormalizer.normalize(name)
        return normalized == "SessionStart" || normalized == "SessionEnd"
    }
}
