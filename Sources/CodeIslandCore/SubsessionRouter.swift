import Foundation

/// Where Agent Sub-Sessions puts one hook of a child session.
public enum SubsessionPlacement: Equatable, Sendable {
    /// The hook stays as it came.
    case unchanged
    /// The hook is answered without reaching a card.
    case hidden
    /// The child's own card, linked to its parent's: its turns are the
    /// parent's business, so the card never rings, pops a completion card or
    /// sends a push; its approvals and questions still do.
    case ownCard(linkedTo: String)
    /// Folded into card `into` as one of its subagents.
    case fold(into: String)
}

/// Agent Sub-Sessions, the same way for every kind of child session.
///
/// HookServer asks ``link(in:context:now:)`` whose child a hook is, then
/// ``route(_:link:mode:cards:isBlockingRequest:)`` rewrites the hook for
/// where it belongs:
/// - **Show separately**: the child keeps its own card, linked to its parent
///   (``linkedParentKey``) so the reducer keeps it quiet.
/// - **Merge into main**: the child folds into its parent's card as a
///   subagent (``fold(_:link:into:)``), or — for a grandchild — into the
///   card its parent is folded into. With no card to fold into, it keeps a
///   linked card of its own.
/// - **Hide**: the hook is dropped, but never answered on the user's behalf
///   (#165): a request the child is blocked on surfaces on a card of its own
///   (a plugin proxy's goes back to its agent undecided).
///
/// A child stays where the router put it until it ends — on its linked card,
/// or as a row of the card it is folded into — whatever the setting says
/// now. AppState's passes over known cards (`applyCurrentPluginSessionMode`)
/// move Codex and Cursor children when the setting changes; the router then
/// follows them.
public enum SubsessionRouter {
    /// The card a child that lands on a card of its own works for, stamped by
    /// the router: the reducer reads it into ``SessionSnapshot/parentSessionId``.
    public static let linkedParentKey = "_subsession_parent"
    /// On a hook folded into its parent's card: the child's
    /// ``SubsessionLink/Kind``. The reducer marks the child's row with it.
    public static let foldedKey = "_subsession_folded"

    public enum Outcome: Equatable, Sendable {
        case unchanged
        /// The payload was rewritten (folded, or linked to its parent).
        case rewritten
        /// Answer the hook with `{}`; no card sees it.
        case hidden
    }

    // MARK: - Resolution

    /// Whose child the hook in `raw` is, from the first resolver that knows:
    /// what the child says itself, then where it already is, then each
    /// agent's own evidence. nil for a hook of a session nobody spawned.
    public static func link(
        in raw: [String: Any],
        context: SubsessionContext,
        now: Date = Date()
    ) -> SubsessionLink? {
        // A declared parent is the child's own word; no heuristic below may
        // second-guess it.
        let link = DeclaredSubsession.link(in: raw)
            ?? foldedLink(in: raw, cards: context.cards)
            ?? CursorSubsessionRouter.link(in: raw, context: context, now: now)
            ?? PluginProxySubsession.link(in: raw, context: context, now: now)
            ?? CodexThreadSubsession.link(in: raw, context: context, now: now)
        // A session cannot be its own parent.
        guard let link, link.isProviderFolded || link.parentCardId != link.childCardId else { return nil }
        return link
    }

    /// A child already folded into a card follows its row there, whatever its
    /// hooks say now (a Cursor Task's IDE process may no longer single out
    /// its chat). Declared rows go by the child's card id, the others by its
    /// raw session id.
    private static func foldedLink(in raw: [String: Any], cards: [String: SessionSnapshot]) -> SubsessionLink? {
        guard let sessionId = sessionId(in: raw) else { return nil }
        let cardId = HookEvent.cardSessionId(forRawSessionId: sessionId, in: raw)
        for agentId in cardId == sessionId ? [cardId] : [cardId, sessionId] {
            for (hostId, host) in cards where hostId != cardId {
                guard let row = host.subagents[agentId], let kind = row.subsessionKind else { continue }
                return SubsessionLink(
                    kind: kind,
                    childCardId: cardId,
                    agentId: agentId,
                    parentCardId: hostId,
                    agentType: row.agentType
                )
            }
        }
        return nil
    }

    // MARK: - Placement

    /// Where `mode` puts this hook of `link`'s child. `isBlockingRequest` is
    /// asked only when it matters: whether the hook is a permission request or
    /// a question the child waits on.
    public static func placement(
        for link: SubsessionLink,
        mode: SubsessionMode,
        cards: [String: SessionSnapshot],
        isBlockingRequest: () -> Bool
    ) -> SubsessionPlacement {
        if link.isProviderFolded {
            guard let filedUnder = link.parentCardId else { return .unchanged }
            let host = providerFiledHost(for: link, filedUnder: filedUnder, in: cards)
            // Hide drops it until a request it is blocked on has put the
            // child on the card.
            if mode == .hide, cards[host]?.subagents[link.agentId] == nil, !isBlockingRequest() {
                return .hidden
            }
            // Show separately and Merge leave it where the agent filed it.
            // One that names no child is folded where it sits, which names
            // it: as it came it would be the parent's own event.
            if host == filedUnder, !link.isFiledAsParentsOwn { return .unchanged }
            return .fold(into: host)
        }

        // A plugin proxy reports its agent's own turn a second way (see
        // ``fold(_:link:into:)``). Hide drops all of it, a request included:
        // answered `{}`, the request is left undecided and the agent asks the
        // user itself (#165), as with no hook installed. A card of its own
        // would show what the agent shows anyway, and stay up until it ended.
        if link.kind == .pluginProxy, mode == .hide {
            return .hidden
        }

        // A child stays where the router put it until it ends: on a card of
        // its own linked to its parent, or as the row it is folded into.
        // Folding or hiding it mid-flight — Agent Sub-Sessions changed under
        // it, or its parent's card turned up late — would strand that card
        // or row. A card the child's hooks built before it was known to be a
        // child (a Codex rollout written after the thread's first hook, a
        // Cursor Task's Claude-format hook) is not linked and holds nothing:
        // Merge folds and Hide hides what follows, and the passes over known
        // cards move the card.
        if let card = cards[link.childCardId],
           card.parentSessionId != nil || link.kind.isAnnouncedByEveryHook {
            return ownCard(link, mode: mode)
        }
        if let host = SubsessionCards.cardHosting(foldedSubsession: link.agentId, in: cards),
           host != link.childCardId {
            return .fold(into: host)
        }

        switch mode {
        case .separate:
            return ownCard(link, mode: mode)
        case .merge:
            return mergeHost(for: link, in: cards).map { .fold(into: $0) } ?? ownCard(link, mode: mode)
        case .hide:
            // Hidden, but never answered on the user's behalf (#165): a
            // request the child is blocked on surfaces on a card of its own,
            // which then shows the child until it ends.
            return isBlockingRequest() ? ownCard(link, mode: mode) : .hidden
        }
    }

    /// The card a hook the agent filed under the parent's session belongs on:
    /// that session's card. A session with no card of its own there is a
    /// thread the agent made a row of another card (Codex files a
    /// grandchild's hooks under its parent thread, whose own hooks are a row
    /// of the root's): the hook joins the child where it already is, or else
    /// the card its parent is a row of, as a declared grandchild does.
    private static func providerFiledHost(
        for link: SubsessionLink,
        filedUnder: String,
        in cards: [String: SessionSnapshot]
    ) -> String {
        if cards[filedUnder] != nil { return filedUnder }
        return SubsessionCards.cardHosting(foldedSubsession: link.agentId, in: cards)
            ?? link.parentAgentId.flatMap { SubsessionCards.cardHosting(subagent: $0, in: cards) }
            ?? filedUnder
    }

    /// The card Merge folds the child into: its parent's — or, for a
    /// grandchild, the card its parent is folded into. An unknown parent is
    /// not invented (``SubsessionLink/Kind/mayCreateParentCard``): the child
    /// keeps a card of its own, where it is still treated as a child.
    static func mergeHost(for link: SubsessionLink, in cards: [String: SessionSnapshot]) -> String? {
        guard let parent = link.parentCardId else { return nil }
        if cards[parent] != nil { return parent }
        if let parentAgentId = link.parentAgentId,
           let host = SubsessionCards.cardHosting(foldedSubsession: parentAgentId, in: cards) {
            return host
        }
        return link.kind.mayCreateParentCard ? parent : nil
    }

    /// The child on its own card, linked to its parent — unless the parent is
    /// unknown, or only a guess that Show separately does not act on
    /// (``SubsessionLink/isInferred``).
    private static func ownCard(_ link: SubsessionLink, mode: SubsessionMode) -> SubsessionPlacement {
        guard let parent = link.parentCardId,
              parent != link.childCardId,
              !(link.isInferred && mode == .separate) else {
            return .unchanged
        }
        return .ownCard(linkedTo: parent)
    }

    // MARK: - Rewriting

    /// Place one hook of `link`'s child, rewriting `raw` for it.
    public static func route(
        _ raw: inout [String: Any],
        link: SubsessionLink,
        mode: SubsessionMode,
        cards: [String: SessionSnapshot],
        isBlockingRequest: () -> Bool
    ) -> Outcome {
        switch placement(for: link, mode: mode, cards: cards, isBlockingRequest: isBlockingRequest) {
        case .unchanged:
            return .unchanged
        case .hidden:
            return .hidden
        case .ownCard(let parent):
            return stamp(&raw, parent: parent) ? .rewritten : .unchanged
        case .fold(let host):
            if fold(&raw, link: link, into: host) { return .rewritten }
            // The payload cannot address that card: the child keeps one of
            // its own — or, filed under its parent's session, stays there.
            guard !link.isProviderFolded,
                  case .ownCard(let parent) = ownCard(link, mode: mode) else { return .unchanged }
            return stamp(&raw, parent: parent) ? .rewritten : .unchanged
        }
    }

    /// Rewrite a child's hook onto card `hostCardId` as its subagent
    /// ``SubsessionLink/agentId`` — the one fold for every kind.
    ///
    /// Returns false, leaving `raw` untouched, when the payload cannot
    /// address that card: a remote child's hook can only land on a card of
    /// the same host, and a Codex Desktop one only on a `codexapp:` card. Nor
    /// can a source whose `agent_id` is not a subagent marker (TRAE) fold.
    ///
    /// Where kinds differ:
    /// - a plugin proxy's hooks join the card as its own events, not as a
    ///   subagent's (see below);
    /// - a Cursor Task's hook keeps or gains a Cursor `_source`.
    @discardableResult
    public static func fold(_ raw: inout [String: Any], link: SubsessionLink, into hostCardId: String) -> Bool {
        guard let sessionId = payloadSessionId(addressing: hostCardId, in: raw) else { return false }
        if link.kind == .pluginProxy {
            // A plugin proxy reports its agent's turn a second way: omo runs
            // Claude Code's hooks for the session's prompts, tools and Stop.
            // Those are the card's own events. As a subagent row they would
            // wait for a Stop omo never sends for the sessions it spawns, and
            // hold the card's completion until then.
            raw["session_id"] = sessionId
            removeLinks(from: &raw)
            return true
        }
        // TRAE stamps every hook with the running agent's id, so `agent_id`
        // cannot mark a folded child there.
        guard HookEvent.agentIdMarksSubagent(source: raw["_source"] as? String) else { return false }
        raw["session_id"] = sessionId
        raw["agent_id"] = nonEmptyString(raw["agent_id"]) ?? link.agentId
        if nonEmptyString(raw["agent_type"]) == nil {
            raw["agent_type"] = link.agentType ?? link.kind.defaultAgentType
        }
        raw[foldedKey] = link.kind.rawValue
        // It named the parent of the old `session_id`; the hook is now the
        // host card's, so the link no longer applies.
        removeLinks(from: &raw)
        // Misbranded Claude-default Task hooks must land as Cursor on the parent.
        if link.kind == .cursorTask,
           !CursorSubsessionRouter.isCursorFamilySource((raw["_source"] as? String) ?? (raw["source"] as? String)) {
            raw["_source"] = "cursor"
        }
        return true
    }

    /// Link the child's own card to `parent`. False when the payload already
    /// says so (a declared child names it itself).
    private static func stamp(_ raw: inout [String: Any], parent: String) -> Bool {
        guard parentCardId(in: raw) != parent else { return false }
        raw[linkedParentKey] = parent
        return true
    }

    private static func removeLinks(from raw: inout [String: Any]) {
        raw.removeValue(forKey: DeclaredSubsession.parentKey)
        raw.removeValue(forKey: linkedParentKey)
    }

    /// The `session_id` that makes this payload file under `cardId`, if any.
    static func payloadSessionId(addressing cardId: String, in raw: [String: Any]) -> String? {
        var candidate = cardId
        if let host = remoteHostId(in: raw) {
            let prefix = "remote:\(host):"
            guard cardId.hasPrefix(prefix) else { return nil }
            candidate = String(cardId.dropFirst(prefix.count))
        }
        guard HookEvent.cardSessionId(forRawSessionId: candidate, in: raw) == cardId else {
            return nil
        }
        return candidate
    }

    // MARK: - Reading a routed hook (the reducer)

    /// The card the session whose hook this is works for: what the router
    /// linked it to, or what it declared itself.
    public static func parentCardId(in raw: [String: Any]) -> String? {
        nonEmptyString(raw[linkedParentKey]) ?? DeclaredSubsession.parentSessionId(in: raw)
    }

    /// The kind of child session a hook folded into its parent's card came
    /// from; nil for an agent's own subagent.
    public static func foldedKind(of event: HookEvent) -> SubsessionLink.Kind? {
        (event.rawJSON[foldedKey] as? String).flatMap(SubsessionLink.Kind.init(rawValue:))
    }

    // MARK: - Payload fields

    public static func sessionId(in raw: [String: Any]) -> String? {
        nonEmptyString(raw["session_id"]) ?? nonEmptyString(raw["sessionId"])
    }

    /// The remote host the hook came from (`_remote_host_id`); nil for this
    /// Mac.
    public static func remoteHostId(in raw: [String: Any]) -> String? {
        guard let host = raw["_remote_host_id"] as? String,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return host
    }

    public static func transcriptPath(in raw: [String: Any]) -> String? {
        nonEmptyString(raw["transcript_path"]) ?? nonEmptyString(raw["transcriptPath"])
    }

    /// Positive process id from `_ppid` (Int / Int32 / NSNumber / decimal
    /// String); nil past `pid_t`'s range, which a malformed payload could
    /// otherwise turn into a trap where it is compared with a card's PID.
    public static func positivePpid(in raw: [String: Any]) -> Int? {
        let parsed: Int?
        if let p = raw["_ppid"] as? Int {
            parsed = p
        } else if let p = raw["_ppid"] as? Int32 {
            parsed = Int(p)
        } else if let p = raw["_ppid"] as? NSNumber {
            parsed = p.intValue
        } else if let s = raw["_ppid"] as? String {
            parsed = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            parsed = nil
        }
        guard let parsed, parsed > 0, parsed <= Int(pid_t.max) else { return nil }
        return parsed
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Another agent firing this one's hooks (#123): the bridge marks a hook that
/// came with no `--source` and whose source it inferred from the process tree
/// `_via_plugin` (omo in OpenCode runs Claude Code's hooks). Its parent is
/// the card of the same agent on the same process — a guess.
public enum PluginProxySubsession {
    public static func link(
        in raw: [String: Any],
        context: SubsessionContext,
        now: Date = Date()
    ) -> SubsessionLink? {
        guard (raw["_via_plugin"] as? Bool) == true else { return nil }
        // A hook with no session id lands on AppState's "default" card.
        let childCardId = SubsessionRouter.sessionId(in: raw)
            .map { HookEvent.cardSessionId(forRawSessionId: $0, in: raw) } ?? "default"
        var parentCardId: String?
        if let source = raw["_source"] as? String,
           let ppid = SubsessionRouter.positivePpid(in: raw) {
            parentCardId = SubsessionCards.samePidCard(
                source: source,
                ppid: ppid,
                remoteHostId: SubsessionRouter.remoteHostId(in: raw),
                excluding: childCardId,
                in: context.cards,
                now: now
            )
        }
        return SubsessionLink(
            kind: .pluginProxy,
            childCardId: childCardId,
            agentId: childCardId,
            parentCardId: parentCardId,
            isInferred: true
        )
    }
}
