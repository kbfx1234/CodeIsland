import Foundation
import CodeIslandCore

/// Outcome of applying a `CursorQuestionSignal` to a session snapshot.
enum CursorQuestionApplication: Equatable {
    /// Session is now display-waiting on a Cursor-side question.
    /// `fresh` is false when it was already waiting (prompt refresh only).
    case markedWaiting(fresh: Bool)
    /// A previously pending question was superseded; normal flow resumed.
    case clearedWaiting
    /// Signal did not apply (wrong source, subagent transcript, approval in flight, …).
    case ignored
}

extension AppState {
    /// Start watching a session's transcript file for appended lines. Safe to call
    /// repeatedly with the same (session, path) pair — the tailer reattaches only
    /// when the path actually changed.
    func attachTranscriptTailerIfNeeded(sessionId: String) {
        guard let path = sessions[sessionId]?.transcriptPath, !path.isEmpty else { return }
        if attachedTranscriptPaths[sessionId] == path { return }
        attachedTranscriptPaths[sessionId] = path

        // Backfill messages from the transcript file so recentMessages is populated
        let messages: [ChatMessage]
        if let source = sessions[sessionId]?.source,
           source == "cursor" || source == "cursor-cli" {
            messages = Self.readRecentFromCursorTranscript(path: path).1
        } else if sessions[sessionId]?.source == "codex" {
            messages = Self.readRecentFromCodexTranscript(path: path).1
        } else {
            messages = Self.readRecentFromTranscript(path: path).1
        }
        if !messages.isEmpty, var session = sessions[sessionId] {
            session.recentMessages = messages
            if let lastUser = messages.last(where: { $0.isUser }) {
                session.lastUserPrompt = lastUser.text
            }
            if let lastAssistant = messages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = lastAssistant.text
            }
            sessions[sessionId] = session
        }

        // Recap + model/effort from the transcript tail, by the same rules as
        // live deltas. Authoritative for the recap, so a persisted one that a
        // newer prompt superseded while nobody was watching is dropped here.
        // Its end offset is where the tailer and the checklist backfill pick
        // up, so a line written meanwhile (the prompt that makes this recap
        // stale, Codex's last update_plan) is read by exactly one of them.
        let tailScan = JSONLTailer.scanTailForAttach(path: path)
        if let tailScan,
           var session = sessions[sessionId],
           session.applyTranscriptBackfill(tailScan.delta) {
            sessions[sessionId] = session
        }

        if sessions[sessionId]?.source == "codex",
           let turnStatus = Self.latestCodexTurnStatus(path: path),
           var session = sessions[sessionId] {
            switch turnStatus {
            case .processing:
                session.status = .processing
                session.interrupted = false
                session.taskRoundEnded = false
                if session.source == "codex" {
                    session.liveCodexOutput = nil
                }
            case .idle:
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
            }
            if let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                session.lastActivity = modifiedAt
            }
            sessions[sessionId] = session
        }

        // Cursor stuck-question recovery (#265): if the transcript already ends
        // with an unanswered AskQuestion (e.g. CodeIsland launched or the session
        // was discovered while Cursor sat on a question), surface the wait now
        // instead of showing an endless "thinking". Recency-gated so an idle card
        // over a long-abandoned transcript doesn't resurrect as waiting.
        if let session = sessions[sessionId],
           session.source == "cursor" || session.source == "cursor-cli",
           CursorSessionFolding.parentConversationId(fromTranscriptPath: path) == sessionId,
           let signal = Self.latestCursorTailQuestion(path: path) {
            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let isRecent = modifiedAt.map { Date().timeIntervalSince($0) < Self.cursorQuestionBackfillMaxAge } ?? false
            let skipStalePending: Bool
            if case .pending = signal, !isRecent {
                skipStalePending = true
            } else {
                skipStalePending = false
            }
            if !skipStalePending, var mutable = sessions[sessionId] {
                let waitBefore = displayOnlyWaitKind(forSession: sessionId)
                if Self.applyCursorQuestionSignal(
                    signal,
                    to: &mutable,
                    sessionId: sessionId,
                    transcriptPath: path
                ) != .ignored {
                    sessions[sessionId] = mutable
                    // Found on attach, not asked just now: remind, don't push.
                    noteDisplayOnlyWait(sessionId: sessionId, was: waitBefore)
                }
            }
        }

        // Checklist history is rebuilt off the main actor from the bytes the
        // tailer will not see: everything before the tailer's start offset.
        let attachOffset = tailScan?.endOffset ?? Self.transcriptFileSize(path)
        let attachmentToken = transcriptTailer.attach(
            sessionId: sessionId,
            filePath: path,
            initialOffset: attachOffset
        )
        attachedTranscriptTokens[sessionId] = attachmentToken
        startAgentTaskBackfill(
            sessionId: sessionId,
            path: path,
            endOffset: attachOffset,
            attachmentToken: attachmentToken,
            // A long Codex turn's output often pushes its turn_context out of
            // the tail window; look further back, off the main actor.
            searchCodexModel: sessions[sessionId]?.source == "codex" && tailScan?.delta.modelObservation == nil
        )
    }

    /// Backfill freshness bound for flipping a session into the display-only
    /// question wait from a cold start. Live tail deltas are not age-gated.
    nonisolated static let cursorQuestionBackfillMaxAge: TimeInterval = 30 * 60

    /// Trailing Cursor question state for a whole transcript file, scanned in
    /// bounded chunks (same pattern as `latestCodexTurnStatus`).
    nonisolated static func latestCursorTailQuestion(path: String) -> CursorQuestionSignal? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: 0)
        let chunkSize = 64 * 1024
        var pendingFragment = Data()
        var latestSignal: CursorQuestionSignal?

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            let result = JSONLTailer.scanLines(pendingFragment + chunk)
            pendingFragment = result.trailingFragment
            if let signal = result.delta.cursorQuestion {
                latestSignal = signal
            }
        }

        return latestSignal
    }

    /// Apply a Cursor trailing-question signal to one session snapshot.
    ///
    /// Pure state transition (no side effects) so both the live tail path and the
    /// attach-time backfill share identical rules, and tests can drive it directly:
    /// - `.pending` flips a **main-agent** Cursor session (transcript parent ==
    ///   session id, so folded Task/subagent transcripts never qualify) into
    ///   `.waitingQuestion` with the question text stored for the card. A real
    ///   approval wait is never stomped.
    /// - `.cleared` erases the stored question; if the session was in the
    ///   display-only wait it resumes as `.processing` (follow-up hooks or tail
    ///   deltas refine from there).
    nonisolated static func applyCursorQuestionSignal(
        _ signal: CursorQuestionSignal,
        to session: inout SessionSnapshot,
        sessionId: String,
        transcriptPath: String?
    ) -> CursorQuestionApplication {
        guard session.source == "cursor" || session.source == "cursor-cli" else { return .ignored }

        switch signal {
        case .pending(let prompt):
            guard let transcriptPath,
                  CursorSessionFolding.parentConversationId(fromTranscriptPath: transcriptPath) == sessionId else {
                return .ignored
            }
            // An interactive approval outranks the display-only wait.
            guard session.status != .waitingApproval else { return .ignored }
            let fresh = session.status != .waitingQuestion || session.cursorPendingQuestion == nil
            session.status = .waitingQuestion
            session.cursorPendingQuestion = prompt
            session.currentTool = nil
            session.toolDescription = nil
            session.lastActivity = Date()
            return .markedWaiting(fresh: fresh)

        case .cleared:
            guard session.cursorPendingQuestion != nil else { return .ignored }
            session.cursorPendingQuestion = nil
            if session.status == .waitingQuestion {
                session.status = .processing
            }
            session.lastActivity = Date()
            return .clearedWaiting
        }
    }

    /// Stop watching a session's transcript. Called when the session is removed or
    /// when a new transcript path supersedes an older one.
    func detachTranscriptTailer(sessionId: String) {
        attachedTranscriptPaths.removeValue(forKey: sessionId)
        attachedTranscriptTokens.removeValue(forKey: sessionId)
        pendingAgentTaskBackfills.removeValue(forKey: sessionId)
        transcriptTailer.detach(sessionId: sessionId)
    }

    /// Apply an incremental update produced by the tailer. Runs on the main actor.
    func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        if let attachmentToken = delta.attachmentToken {
            guard attachedTranscriptTokens[delta.sessionId] == attachmentToken,
                  attachedTranscriptPaths[delta.sessionId] == delta.filePath else {
                return
            }
        }
        guard var session = sessions[delta.sessionId] else { return }
        let waitBefore = displayOnlyWaitKind(forSession: delta.sessionId)
        var mutated = false

        if delta.hasActivity {
            session.lastActivity = Date()
            mutated = true
        }

        if let turnStatus = delta.turnStatus {
            switch turnStatus {
            case .processing:
                session.status = .processing
                session.interrupted = false
                session.taskRoundEnded = false
                if session.source == "codex" {
                    session.liveCodexOutput = nil
                }
            case .idle:
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
            }
            // A status-only event is still activity. This matters for a long Codex
            // turn whose transcript has not emitted a message yet.
            session.lastActivity = Date()
            mutated = true
        }

        if let prompt = delta.lastUserPrompt {
            let normalizedIncoming = JSONLTailer.normalizedCursorChatText(from: prompt) ?? prompt
            let normalizedCurrent = session.lastUserPrompt.flatMap {
                JSONLTailer.normalizedCursorChatText(from: $0) ?? $0
            }
            if normalizedCurrent != normalizedIncoming {
                session.lastUserPrompt = normalizedIncoming
                let lastUserText = session.recentMessages.last(where: { $0.isUser })?.text
                let lastNormalized = lastUserText.flatMap {
                    JSONLTailer.normalizedCursorChatText(from: $0) ?? $0
                }
                if lastNormalized != normalizedIncoming {
                    session.addRecentMessage(ChatMessage(isUser: true, text: normalizedIncoming))
                }
                mutated = true
            }
        }
        if let reply = delta.lastAssistantMessage {
            let normalizedIncoming = JSONLTailer.normalizedCursorChatText(from: reply) ?? reply
            let normalizedCurrent = session.lastAssistantMessage.flatMap {
                JSONLTailer.normalizedCursorChatText(from: $0) ?? $0
            }
            if normalizedCurrent != normalizedIncoming {
                session.lastAssistantMessage = normalizedIncoming
                let lastAssistantText = session.recentMessages.last(where: { !$0.isUser })?.text
                let lastNormalized = lastAssistantText.flatMap {
                    JSONLTailer.normalizedCursorChatText(from: $0) ?? $0
                }
                if lastNormalized != normalizedIncoming {
                    session.addRecentMessage(ChatMessage(isUser: false, text: normalizedIncoming))
                }
                mutated = true
            }
            if session.source == "codex", session.liveCodexOutput != normalizedIncoming {
                session.liveCodexOutput = normalizedIncoming
                mutated = true
            }
        }

        // Checklist progress from the transcript: the only channel for Codex
        // update_plan, and the backstop when a Claude hook is missed. A
        // replaced file re-read from its start is history, rebuilt the way an
        // attach backfill is — not replayed as news (a plan finished long ago
        // would flash "all done").
        if delta.replaysWholeFile {
            if replayAgentTaskHistory(delta.taskEvents, sessionId: delta.sessionId, to: &session) {
                mutated = true
            }
        } else if !delta.taskEvents.isEmpty,
           applyAgentTaskTranscriptEvents(delta.taskEvents, sessionId: delta.sessionId, to: &session) {
            mutated = true
        }

        // Cursor question tool has no hook channel (#265) — the transcript tail is
        // the only signal that the agent is blocked on (or resumed from) a question
        // answered inside Cursor's own UI.
        var questionStateChanged = false
        if let signal = delta.cursorQuestion {
            let application = Self.applyCursorQuestionSignal(
                signal,
                to: &session,
                sessionId: delta.sessionId,
                transcriptPath: attachedTranscriptPaths[delta.sessionId]
            )
            if application != .ignored {
                mutated = true
                questionStateChanged = true
            }
            if application == .markedWaiting(fresh: true) {
                SoundManager.shared.handleEvent("PermissionRequest")
            }
        }

        // Recap + model/effort label. Written back without bumping lastActivity:
        // a recap arrives minutes after the turn ended and is not activity.
        let metadataChanged = session.applyTranscriptMetadata(from: delta)
        if delta.modelObservation != nil {
            // Newer than anything the attach-time search can still turn up.
            pendingAgentTaskBackfills[delta.sessionId]?.sawLiveModelObservation = true
        }

        if mutated {
            session.lastActivity = Date()
            sessions[delta.sessionId] = session
        } else if metadataChanged {
            sessions[delta.sessionId] = session
            scheduleSave()
        }
        // Cursor's question (or a transcript turn boundary ending some other
        // display-only wait): reminders, and a push for a question just asked.
        noteDisplayOnlyWait(sessionId: delta.sessionId, was: waitBefore, announce: questionStateChanged)
        if mutated || questionStateChanged {
            // Hooks stay silent while Cursor waits on its question, so nothing
            // else recomputes the aggregated pill/mascot state for this flip.
            refreshDerivedState()
        }
    }
}
