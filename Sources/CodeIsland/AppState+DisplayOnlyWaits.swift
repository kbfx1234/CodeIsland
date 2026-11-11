import Foundation
import CodeIslandCore

/// Display-only waits (`DisplayOnlyWait`): an agent blocked on the user
/// somewhere the island cannot answer — a Claude Desktop Cowork card, Cursor's
/// in-IDE question, an AiWork prompt, a terminal permission prompt, a Codex
/// Desktop thread flag. The session card already shows them; this makes them
/// follow-up reminders and phone pushes like a queued approval / question.
///
/// Every path that can move a session into or out of such a wait reads
/// `displayOnlyWaitKind(forSession:)` before its change and reports with
/// `noteDisplayOnlyWait` after it; only a real transition does any work, so
/// the hot paths (hook events, transcript deltas, AiWork tokens) pay two
/// dictionary reads. A wait that begins restarts its reminders and, from a
/// live source the island can never own, pushes once; updates while it
/// continues push nothing.
extension AppState {
    /// The kind this session is display-only waiting on right now, or nil.
    func displayOnlyWaitKind(forSession sessionId: String) -> FollowUpReminderKind? {
        guard let status = sessions[sessionId]?.status,
              status == .waitingApproval || status == .waitingQuestion else { return nil }
        return DisplayOnlyWait.kind(status: status, islandHoldsRequest: islandHoldsRequest(forSession: sessionId))
    }

    /// Sessions display-only waiting on `kind`, for the follow-up scheduler.
    func displayOnlyWaitingSessionIds(kind: FollowUpReminderKind) -> Set<String> {
        let held = Set(permissionQueue.map { $0.event.sessionId ?? "default" })
            .union(questionQueue.map { $0.event.sessionId ?? "default" })
        return DisplayOnlyWait.sessionIds(waitingOn: kind, in: sessions, islandRequestSessionIds: held)
    }

    /// Queued — dismissed or not — means the island owns the wait.
    private func islandHoldsRequest(forSession sessionId: String) -> Bool {
        permissionQueue.contains { ($0.event.sessionId ?? "default") == sessionId }
            || questionQueue.contains { ($0.event.sessionId ?? "default") == sessionId }
    }

    /// Report a change that may have moved a session into or out of a
    /// display-only wait.
    ///
    /// - `before`: `displayOnlyWaitKind(forSession:)` read before the change.
    /// - `asking`: what the wait asks, when the source knows more than the
    ///   session card does (the Cowork card on top, the AiWork event). nil
    ///   keeps what a continuing wait already recorded.
    /// - `announce`: a live wait from a source the island can never own
    ///   (Cowork, Cursor's in-IDE question, AiWork) pushes when it begins.
    ///   Launch rebuilds and backfills only remind; so do sources whose
    ///   request the island may be about to queue — a terminal
    ///   `permission_prompt` races its own PermissionRequest hook, and a push
    ///   from it would take the dedupe slot of the richer queued push.
    func noteDisplayOnlyWait(
        sessionId: String,
        was before: FollowUpReminderKind?,
        asking content: PushContent? = nil,
        announce: Bool = false
    ) {
        let current = displayOnlyWaitKind(forSession: sessionId)
        guard before != nil || current != nil else { return }
        // A wait that ended or now asks something else frees its push slot.
        PushNotifier.shared.requestsChanged()
        guard let current else {
            displayOnlyWaitAsks.removeValue(forKey: sessionId)
            followUps.displayOnlyWaitsChanged()
            return
        }
        let began = before != current
        if let content, Self.followUpKind(asking: content) == current {
            displayOnlyWaitAsks[sessionId] = content
        } else if began {
            // Whatever an earlier wait asked is not this one's question.
            displayOnlyWaitAsks.removeValue(forKey: sessionId)
        }
        guard began else { return }
        let attention = decideAttention(.displayOnlyWaitBegan(current, announce: announce), sessionId: sessionId)
        if case .restartWait(let kind)? = attention.followUp {
            followUps.displayOnlyWaitsChanged(began: FollowUpReminderScheduler.Key(kind, sessionId))
        }
        if let push = attention.push {
            pushDisplayOnlyWait(sessionId: sessionId, smartSuppressed: push.smartSuppressed)
        }
    }

    // MARK: - Push

    /// The first push for a display-only wait, as `AttentionPolicy` decided
    /// it. Same gates as a queued approval from here: only while away, Smart
    /// Suppress while present, dedupe, rate limit, per-channel kind filter.
    @discardableResult
    func pushDisplayOnlyWait(sessionId: String, smartSuppressed: Bool) -> PushDecision {
        guard let content = displayOnlyWaitPushContent(forSession: sessionId) else {
            return .skipped(.nothingPending)
        }
        return PushNotifier.shared.notify(
            content,
            subject: pushSubject(for: sessionId),
            smartSuppressed: smartSuppressed,
            request: pushRequest(forDisplayOnlyWait: sessionId, asking: content)
        )
    }

    /// What the session's display-only wait asks, and where to answer it;
    /// nil unless it is waiting that way (on `kind`, when given).
    func displayOnlyWaitPushContent(
        forSession sessionId: String,
        kind: FollowUpReminderKind? = nil
    ) -> PushContent? {
        guard let waiting = displayOnlyWaitKind(forSession: sessionId),
              kind == nil || kind == waiting else { return nil }
        let session = sessions[sessionId]
        let recorded = displayOnlyWaitAsks[sessionId].flatMap {
            Self.followUpKind(asking: $0) == waiting ? $0 : nil
        }
        return .answerElsewhere(
            pending: recorded ?? DisplayOnlyWait.fallbackContent(kind: waiting, session: session),
            app: session.flatMap(DisplayOnlyWait.answerPlace)
        )
    }

    // MARK: - Sources

    /// A hook event's own account of a terminal permission prompt: the
    /// `Notification(permission_prompt)` text ("Claude needs your permission
    /// to use Bash"). The tool fields on the card may still describe the step
    /// before it.
    nonisolated static func displayOnlyWaitAsk(forHookEvent event: HookEvent, normalizedEventName: String) -> PushContent? {
        guard normalizedEventName == "Notification",
              notificationKind(from: event) == "permission_prompt" else { return nil }
        let message = ["message", "text", "summary"].lazy
            .compactMap { event.rawJSON[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return .permission(tool: nil, detail: message)
    }

    private nonisolated static func followUpKind(asking content: PushContent) -> FollowUpReminderKind? {
        switch content.kind {
        case .permission: return .approval
        case .question: return .question
        case .completion, .error, .reminder: return nil
        }
    }
}
