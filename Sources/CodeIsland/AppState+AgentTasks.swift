import Foundation
import CodeIslandCore

/// An attach-time checklist backfill that is still scanning — and, for a
/// Codex rollout whose tail window held no `turn_context`, the model/effort
/// search that rides along with it.
struct PendingAgentTaskBackfill {
    /// Tailer attachment the scan belongs to; a re-attach supersedes it.
    let attachmentToken: UUID
    /// Tail events that landed while the scan ran. They are newer than every
    /// scanned byte, so they replay on top of the rebuilt list.
    var bufferedEvents: [AgentTaskEvent] = []
    /// A live line named the model while the scan ran; history must not
    /// overwrite it.
    var sawLiveModelObservation = false
}

extension AppState {
    /// Rebuild a session's checklist (TaskCreate / TodoWrite / update_plan)
    /// from transcript history without blocking the main actor — transcripts
    /// run to tens of MB.
    ///
    /// `endOffset` is the offset the tailer starts reading at, so the scan and
    /// the live tail read disjoint bytes and no operation or prompt is seen
    /// twice — or by neither. With `searchCodexModel`, the last `turn_context`
    /// before it is looked up too: the attach-time tail window often misses
    /// it, leaving the card without its reasoning effort until the next turn.
    func startAgentTaskBackfill(
        sessionId: String,
        path: String,
        endOffset: UInt64,
        attachmentToken: UUID,
        searchCodexModel: Bool = false
    ) {
        guard endOffset > 0 else {
            pendingAgentTaskBackfills.removeValue(forKey: sessionId)
            return
        }
        pendingAgentTaskBackfills[sessionId] = PendingAgentTaskBackfill(attachmentToken: attachmentToken)
        Task.detached(priority: .utility) { [weak self] in
            let backfill = AgentTaskTranscript.scanFile(atPath: path, endOffset: endOffset)
            let codexModel = searchCodexModel
                ? ModelObservation.latestCodexTurnContext(path: path, endOffset: endOffset)
                : nil
            await self?.finishAgentTaskBackfill(
                sessionId: sessionId,
                attachmentToken: attachmentToken,
                backfill: backfill,
                codexModel: codexModel
            )
        }
    }

    func finishAgentTaskBackfill(
        sessionId: String,
        attachmentToken: UUID,
        backfill: AgentTaskTranscript.Backfill?,
        codexModel: ModelObservation? = nil
    ) {
        guard let pending = pendingAgentTaskBackfills[sessionId],
              pending.attachmentToken == attachmentToken else { return }
        pendingAgentTaskBackfills.removeValue(forKey: sessionId)
        guard attachedTranscriptTokens[sessionId] == attachmentToken,
              var session = sessions[sessionId] else { return }
        var changed = false
        if let codexModel, !pending.sawLiveModelObservation,
           session.applyBackfilledModelObservation(codexModel) {
            changed = true
        }
        if let backfill {
            let rebuilt = Self.agentTasksAfterBackfill(
                live: session.agentTasks,
                backfill: backfill,
                bufferedEvents: pending.bufferedEvents,
                now: Date()
            )
            if rebuilt != session.agentTasks {
                session.agentTasks = rebuilt
                changed = true
            }
        }
        guard changed else { return }
        sessions[sessionId] = session
        scheduleSave()
    }

    /// The list after an attach-time scan. A scan without checklist-building
    /// operations (prompts and unrelated tool failures don't count) leaves
    /// the live list (which already holds the buffered tail events) alone;
    /// otherwise history is replayed and the buffered tail events are applied
    /// on top, as live events.
    nonisolated static func agentTasksAfterBackfill(
        live: AgentTaskList,
        backfill: AgentTaskTranscript.Backfill,
        bufferedEvents: [AgentTaskEvent],
        now: Date
    ) -> AgentTaskList {
        guard backfill.events.contains(where: \.buildsList) else { return live }
        var board = AgentTaskList.rebuilt(
            fromTranscript: backfill.events,
            coversWholeTranscript: backfill.coversWholeFile,
            live: live
        )
        board.apply(bufferedEvents, now: now)
        return board
    }

    /// Apply checklist events from a transcript tail delta. Returns whether
    /// the visible list changed.
    func applyAgentTaskTranscriptEvents(
        _ events: [AgentTaskEvent],
        sessionId: String,
        to session: inout SessionSnapshot
    ) -> Bool {
        pendingAgentTaskBackfills[sessionId]?.bufferedEvents.append(contentsOf: events)
        guard session.agentTasks.apply(events, now: Date()) else { return false }
        // Codex plans only ever arrive here — no hook would persist them.
        scheduleSave()
        return true
    }

    /// Rebuild the checklist from a replaced transcript that the tailer
    /// re-read from its start. That covers the whole new file, so an attach
    /// backfill still scanning the old one is moot.
    func replayAgentTaskHistory(
        _ events: [AgentTaskEvent],
        sessionId: String,
        to session: inout SessionSnapshot
    ) -> Bool {
        pendingAgentTaskBackfills.removeValue(forKey: sessionId)
        let rebuilt = AgentTaskList.rebuilt(
            fromTranscript: events,
            coversWholeTranscript: true,
            live: session.agentTasks
        )
        let changed = rebuilt != session.agentTasks
        // Assigned even when the rows match: the replay also rebuilt the turn
        // bookkeeping that equality ignores.
        session.agentTasks = rebuilt
        if changed { scheduleSave() }
        return changed
    }

    /// Current byte size of a transcript, or 0 when unreadable.
    nonisolated static func transcriptFileSize(_ path: String) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }
}
