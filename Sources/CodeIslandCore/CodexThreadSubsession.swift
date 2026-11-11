import Foundation

/// The parent a Codex subagent thread's rollout `session_meta` (or Codex's
/// `thread_spawn_edges` table) names.
public struct CodexSubagentMetadata: Equatable, Sendable {
    public let parentThreadId: String
    public let agentType: String?
    public let agentNickname: String?
    /// The thread's own id (`session_meta.payload.id`), when the source names it.
    public let threadId: String?

    public init(parentThreadId: String, agentType: String?, agentNickname: String?, threadId: String? = nil) {
        self.parentThreadId = parentThreadId
        self.agentType = agentType
        self.agentNickname = agentNickname
        self.threadId = threadId
    }
}

/// What a Codex rollout's first line says about the thread.
public enum CodexTranscriptSubagentInspection: Equatable, Sendable {
    /// The first line could not be established as a valid `session_meta`.
    case unavailable
    /// A valid root `session_meta` explicitly contains no subagent relation.
    case root
    case subagent(CodexSubagentMetadata)

    public var metadata: CodexSubagentMetadata? {
        if case .subagent(let metadata) = self { return metadata }
        return nil
    }
}

/// What each Codex rollout says about its thread's parent, read once per
/// rollout: the router asks on every Codex hook, and a rollout's first line
/// can be large (`base_instructions`). A thread's hooks name its own
/// rollout, so that is once per thread. The answer is the file's, not the
/// session's a hook is filed under: Codex has filed a subagent's hooks under
/// its parent's session id.
///
/// A rollout is written lazily, so a thread's first hooks can come before
/// its `session_meta` line: an unreadable rollout is read again on a
/// schedule (`retryDelays` after the first try, at the first hook due), then
/// left alone. A root or subagent answer never changes and is kept.
///
/// Main-actor state: the app reads and fills it from hook routing and from
/// the Agent Sub-Sessions passes over known cards.
public final class CodexRolloutCache {
    public static let defaultRetryDelays: [TimeInterval] = [0, 1, 5, 15, 45, 120]

    private enum Entry {
        case settled(CodexTranscriptSubagentInspection)
        /// Unreadable so far: `attempts` reads since `since`.
        case unread(since: Date, attempts: Int)
    }

    private var entries: [String: Entry] = [:]
    private let read: (String) -> CodexTranscriptSubagentInspection
    private let retryDelays: [TimeInterval]
    private let capacity: Int

    /// - Parameter read: reads a rollout's first line; called on the caller's
    ///   thread.
    public init(
        retryDelays: [TimeInterval] = CodexRolloutCache.defaultRetryDelays,
        capacity: Int = 512,
        read: @escaping (String) -> CodexTranscriptSubagentInspection
    ) {
        self.retryDelays = retryDelays
        self.capacity = capacity
        self.read = read
    }

    /// What the rollout at `transcriptPath` says, reading it only when the
    /// cache has no answer yet and a read is due.
    public func inspection(
        transcriptPath: String,
        now: Date = Date()
    ) -> CodexTranscriptSubagentInspection {
        switch entries[transcriptPath] {
        case .settled(let inspection)?:
            return inspection
        case .unread(let since, let attempts)?:
            guard attempts < retryDelays.count,
                  now >= since.addingTimeInterval(retryDelays[attempts]) else {
                return .unavailable
            }
            return readAndStore(path: transcriptPath, since: since, attempts: attempts)
        case nil:
            return readAndStore(path: transcriptPath, since: now, attempts: 0)
        }
    }

    private func readAndStore(
        path: String,
        since: Date,
        attempts: Int
    ) -> CodexTranscriptSubagentInspection {
        let inspection = read(path)
        if entries[path] == nil, entries.count >= capacity {
            // Threads that ended long ago; the live ones are read again once.
            entries.removeAll(keepingCapacity: true)
        }
        switch inspection {
        case .unavailable:
            entries[path] = .unread(since: since, attempts: attempts + 1)
        case .root, .subagent:
            entries[path] = .settled(inspection)
        }
        return inspection
    }
}

/// Codex's half of Agent Sub-Sessions: the parent of a Codex subagent thread.
///
/// Codex has filed a subagent thread's hooks three ways:
/// - under the thread's own `session_id`, with nothing naming its parent:
///   the parent comes from the thread's rollout (`session_meta`), or — while
///   that is not readable yet — from the parent's CLI process, which runs
///   the child;
/// - under the root session's id, with the thread as `agent_id` and its role
///   as `agent_type` (current Codex): the hook already sits on the parent's
///   card as a subagent;
/// - under its parent's id with nothing naming the thread but its rollout
///   (a thread Codex does not report as a subagent): the hook sits on the
///   parent's card as the parent's own, until the router names the thread.
public enum CodexThreadSubsession {
    public static func link(
        in raw: [String: Any],
        context: SubsessionContext,
        now: Date = Date()
    ) -> SubsessionLink? {
        guard (raw["_via_plugin"] as? Bool) != true,
              SessionSnapshot.normalizedSupportedSource(raw["_source"] as? String) == "codex",
              let sessionId = SubsessionRouter.sessionId(in: raw) else {
            return nil
        }
        let agentId = SubsessionRouter.nonEmptyString(raw["agent_id"])

        if let agentId, agentId != sessionId {
            return SubsessionLink(
                kind: .codexThread,
                childCardId: HookEvent.cardSessionId(forRawSessionId: agentId, in: raw),
                agentId: agentId,
                parentCardId: HookEvent.cardSessionId(forRawSessionId: sessionId, in: raw),
                // The session filed under may be a thread with no card of
                // its own, a row of the root's (a grandchild's hook).
                parentAgentId: sessionId,
                isProviderFolded: true
            )
        }

        let childCardId = HookEvent.cardSessionId(forRawSessionId: sessionId, in: raw)
        let termBundleId = raw["_term_bundle"] as? String
        let remoteHostId = SubsessionRouter.remoteHostId(in: raw)
        // A remote thread's rollout lives on its own host.
        let inspection: CodexTranscriptSubagentInspection
        if remoteHostId == nil, let path = SubsessionRouter.transcriptPath(in: raw) {
            inspection = context.codexRolloutInspection(transcriptPath: path)
        } else {
            inspection = .unavailable
        }
        let metadata = inspection.metadata
        var parentCardId = metadata.flatMap {
            SubsessionCards.codexParentCard(
                threadId: $0.parentThreadId,
                childTermBundleId: termBundleId,
                in: context.cards
            )
        }

        // The rollout is a subagent's, yet the hook is filed under that
        // subagent's parent (whether or not its card exists yet) with no
        // `agent_id`: a thread Codex does not report as a subagent. It sits
        // on the parent's card, but as the parent's own event: the thread's
        // Stop would end the parent's turn. It goes by the thread's own id.
        if let metadata,
           parentCardId == childCardId
            || HookEvent.cardSessionId(forRawSessionId: metadata.parentThreadId, in: raw) == childCardId {
            let threadId = metadata.threadId ?? sessionId
            return SubsessionLink(
                kind: .codexThread,
                childCardId: HookEvent.cardSessionId(forRawSessionId: threadId, in: raw),
                agentId: threadId,
                parentCardId: childCardId,
                parentAgentId: sessionId,
                agentType: metadata.agentType,
                isProviderFolded: true,
                isFiledAsParentsOwn: true
            )
        }

        // Current Codex hook payloads do not expose parent session metadata
        // for native subagents, but child sessions run inside the same Codex
        // CLI process as their parent. Require an already-active same-PID
        // Codex session so a normal follow-up thread in an idle process stays
        // separate. A rollout that says the thread is a root is the last word.
        //
        // Every Codex Desktop thread runs in the one shared app-server, so a
        // same-PID card says nothing about parentage there (it can even be
        // the thread's own card). Desktop children are found by metadata.
        if parentCardId == nil,
           inspection != .root,
           termBundleId != "com.openai.codex",
           let ppid = SubsessionRouter.positivePpid(in: raw) {
            parentCardId = SubsessionCards.samePidCard(
                source: "codex",
                ppid: ppid,
                remoteHostId: remoteHostId,
                excluding: childCardId,
                requireActive: agentId == nil,
                in: context.cards,
                now: now
            )
        }

        guard metadata != nil || parentCardId != nil else { return nil }
        return SubsessionLink(
            kind: .codexThread,
            childCardId: childCardId,
            agentId: agentId ?? sessionId,
            // A parent thread the island shows no card for yet still makes
            // this thread a child: the card its own hooks would build.
            parentCardId: parentCardId ?? metadata.map {
                HookEvent.cardSessionId(forRawSessionId: $0.parentThreadId, in: raw)
            },
            parentAgentId: metadata?.parentThreadId,
            agentType: metadata?.agentType,
            // Without a rollout to say so, the shared process is the only
            // sign this thread is a child at all.
            isInferred: metadata == nil
        )
    }
}
