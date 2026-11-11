import Foundation

/// A child session that names the session it works for (#378).
///
/// Some agents run each delegated task as a CLI session of its own: a
/// pi-subagents child is a full pi session in a detached runner, loading the
/// same CodeIsland extension as its parent. Nothing about such a session says
/// "subagent" unless it is told, so the child says so itself:
/// `_parent_session_id` carries the parent's session id, in the same form as
/// `session_id`. Agent Sub-Sessions then applies to it as to every other kind
/// of child (``SubsessionRouter``), and its turns are never mistaken for the
/// user's own. Any agent can send it.
public enum DeclaredSubsession {
    /// Payload key holding the parent's session id.
    public static let parentKey = "_parent_session_id"

    /// The card key of the parent this payload's session declares, or nil.
    /// Filed like `session_id` (remote and Codex Desktop namespaces), so it
    /// names the parent's card exactly.
    public static func parentSessionId(in raw: [String: Any]) -> String? {
        guard let parent = SubsessionRouter.nonEmptyString(raw[parentKey]) else { return nil }
        // A session cannot be its own parent: a malformed declaration.
        if parent == SubsessionRouter.sessionId(in: raw) { return nil }
        return HookEvent.cardSessionId(forRawSessionId: parent, in: raw)
    }

    /// The link a child that names its parent carries in every hook. As a
    /// folded row it goes by its card id, which is what a grandchild names.
    public static func link(in raw: [String: Any]) -> SubsessionLink? {
        guard let parentCardId = parentSessionId(in: raw),
              let rawChildId = SubsessionRouter.sessionId(in: raw) else {
            return nil
        }
        let childCardId = HookEvent.cardSessionId(forRawSessionId: rawChildId, in: raw)
        return SubsessionLink(
            kind: .declared,
            childCardId: childCardId,
            agentId: childCardId,
            parentCardId: parentCardId,
            parentAgentId: parentCardId
        )
    }
}
