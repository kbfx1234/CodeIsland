import Foundation

/// A wait the island mirrors but cannot answer.
///
/// Some agents block on the user somewhere the island has no channel into:
/// Claude Desktop's Cowork permission cards, Cursor's in-IDE AskQuestion,
/// AiWork's approval / plan confirmation / question prompts, a terminal's own
/// permission prompt announced by a `Notification(permission_prompt)` hook, a
/// Codex Desktop thread flagged `waitingOnApproval` / `waitingOnUserInput`.
/// Each of them only sets the session's status. Nothing is queued, so there
/// is no card to answer: the session card says where to go, and a click takes
/// the user there.
///
/// Whether a session waits display-only is read off the session, never
/// remembered: it does for exactly as long as its status says it is blocked
/// on the user and the island holds no request for it. A request the island
/// holds — queued, or queued and dismissed — is the island's own business.
public enum DisplayOnlyWait {
    /// Claude Desktop hosts Cowork tasks and its own Code-tab sessions.
    static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

    /// The follow-up kind a session is display-only waiting on, or nil.
    public static func kind(status: AgentStatus, islandHoldsRequest: Bool) -> FollowUpReminderKind? {
        guard !islandHoldsRequest else { return nil }
        switch status {
        case .waitingApproval: return .approval
        case .waitingQuestion: return .question
        case .idle, .processing, .running: return nil
        }
    }

    /// Every session display-only waiting on `kind`.
    public static func sessionIds(
        waitingOn kind: FollowUpReminderKind,
        in sessions: [String: SessionSnapshot],
        islandRequestSessionIds: Set<String>
    ) -> Set<String> {
        var waiting: Set<String> = []
        for (sessionId, session) in sessions
        where Self.kind(status: session.status, islandHoldsRequest: islandRequestSessionIds.contains(sessionId)) == kind {
            waiting.insert(sessionId)
        }
        return waiting
    }

    /// Where the user has to go to answer, as a push names it: the app that
    /// hosts the session (Claude Desktop, Cursor, AiWork, Codex) or the
    /// terminal it runs in. nil for an SSH session — its prompt sits in a
    /// terminal on another machine — and when nothing is known.
    public static func answerPlace(for session: SessionSnapshot) -> String? {
        guard !session.isRemote else { return nil }
        // The card badge says "Claude", which on a phone reads as the model.
        if session.termBundleId == claudeDesktopBundleId { return "Claude Desktop" }
        return nonEmpty(session.terminalName)
    }

    // MARK: - What is being asked

    /// From the session alone, for a wait whose source left nothing richer (a
    /// Codex Desktop thread flag, a wait rebuilt at launch). Only fields owned
    /// by the wait itself are read: `currentTool` / `toolDescription` can
    /// still describe the step before it.
    public static func fallbackContent(kind: FollowUpReminderKind, session: SessionSnapshot?) -> PushContent {
        switch kind {
        case .question:
            return question(session?.cursorPendingQuestion)
        case .approval, .completion:
            return .permission(tool: nil, detail: nil)
        }
    }

    /// Claude Desktop Cowork: the card on top in Claude Desktop.
    public static func content(forCowork audit: CoworkAuditState) -> PushContent? {
        guard let active = audit.activePermission else { return nil }
        switch audit.phase {
        case .waitingApproval:
            return .permission(tool: nonEmpty(active.toolName), detail: nonEmpty(active.detail))
        case .waitingQuestion:
            return question(active.detail)
        case .idle, .processing:
            return nil
        }
    }

    /// AiWork: the stream event that opened the wait.
    public static func content(forAiWorkEvent name: String, data: [String: AnyCodableLike]?) -> PushContent? {
        switch name {
        case "stream.approval_required", "stream.plan_confirmation_required":
            let detail = nonEmpty(data?["command"]?.asString)
                ?? nonEmpty(data?["reason"]?.asString)
                ?? nonEmpty(data?["message"]?.asString)
                ?? nonEmpty(AiWorkStatusMapper.toolDescription(from: data))
            return .permission(tool: nonEmpty(AiWorkStatusMapper.toolName(from: data)), detail: detail)
        case "stream.question_required":
            return question(nonEmpty(data?["message"]?.asString) ?? AiWorkStatusMapper.progressText(from: data))
        default:
            return nil
        }
    }

    /// A single question, or an empty one when its text is unknown (the push
    /// then only says who is asking and where to answer).
    static func question(_ text: String?) -> PushContent {
        .question(items: nonEmpty(text).map { [PushQuestionItem(question: $0)] } ?? [], isSecret: false)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
