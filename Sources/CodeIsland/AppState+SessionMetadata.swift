import Foundation
import CodeIslandCore

/// Where one subagent's own model/effort is being looked for.
struct SubagentModelRead {
    /// Reads started so far; they stop at `AppState.subagentModelReadMaxAttempts`.
    var attempts = 0
    var retryAt: Date = .distantPast
    var inFlight = false
    /// The Claude subagent's transcript once found, so a retry skips the search.
    var transcriptPath: String?
}

/// Transcript-derived session metadata that hooks don't carry: a subagent's
/// own model / reasoning effort. (The session recap and the main thread's
/// model ride the transcript tailer — see `applyTranscriptDelta`.)
extension AppState {
    /// First wait before re-reading a subagent transcript that has no
    /// assistant turn yet (SubagentStart fires before the first one is
    /// written); it doubles on every miss, up to the cap.
    nonisolated static let subagentModelReadRetryInterval: TimeInterval = 2
    nonisolated static let subagentModelReadMaxRetryInterval: TimeInterval = 60
    /// A subagent whose transcript still names no model after this many reads
    /// (about three minutes of hooks) stays unlabeled rather than costing a
    /// file search on every hook for as long as it runs.
    nonisolated static let subagentModelReadMaxAttempts = 8

    /// Where a subagent's own model is recorded.
    enum SubagentModelSource: Sendable {
        /// A Claude subagent's own transcript, next to the parent's.
        case claude(parentTranscriptPath: String, agentId: String, knownPath: String?)
        /// A Codex child thread's own rollout.
        case codexRollout(path: String)
    }

    /// Give a subagent its own model/effort, read from the child's transcript.
    ///
    /// Claude Code hooks never say which model a subagent runs, and Codex child
    /// hooks carry the model but not the effort. Borrowing the parent's values
    /// would mislabel every Task that runs on a different model, so the child's
    /// own transcript is the source. The read runs off the main actor; a
    /// successful one is cached per agent id because Codex recreates the
    /// SubagentState on every child turn.
    func maybeBackfillSubagentModel(sessionId: String, agentId: String, event: HookEvent) {
        // A remote child's transcript paths name files on its own host.
        guard let session = sessions[sessionId], !session.isRemote,
              let subagent = session.subagents[agentId] else { return }

        if let cached = subagentModelObservations[sessionId]?[agentId] {
            applySubagentModel(cached, sessionId: sessionId, agentId: agentId)
            return
        }
        guard subagent.model == nil || subagent.reasoningEffort == nil else { return }
        var read = subagentModelReads[sessionId]?[agentId] ?? SubagentModelRead()
        guard !read.inFlight,
              read.attempts < Self.subagentModelReadMaxAttempts,
              read.retryAt <= Date() else { return }

        let source: SubagentModelSource
        switch SessionSnapshot.normalizedSupportedSource(session.source) {
        case "claude":
            guard let parentPath = session.transcriptPath else { return }
            // SubagentStop names the child's transcript; other hooks don't.
            let hinted = (event.rawJSON["agent_transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            source = .claude(
                parentTranscriptPath: parentPath,
                agentId: agentId,
                knownPath: read.transcriptPath ?? hinted
            )
        case "codex":
            // Child-thread hooks carry the child's own rollout path.
            guard let childPath = event.rawJSON["transcript_path"] as? String,
                  !childPath.isEmpty, childPath != session.transcriptPath else { return }
            source = .codexRollout(path: childPath)
        default:
            // No child transcript to read; a model on the child's own hooks
            // (recordSubagentModel in the reducer) is all there is.
            read.attempts = Self.subagentModelReadMaxAttempts
            subagentModelReads[sessionId, default: [:]][agentId] = read
            return
        }

        read.attempts += 1
        read.inFlight = true
        subagentModelReads[sessionId, default: [:]][agentId] = read
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.readSubagentModel(from: source)
            await self?.finishSubagentModelRead(
                sessionId: sessionId,
                agentId: agentId,
                observation: result.observation,
                transcriptPath: result.transcriptPath
            )
        }
    }

    func finishSubagentModelRead(
        sessionId: String,
        agentId: String,
        observation: ModelObservation?,
        transcriptPath: String?
    ) {
        // Gone with its session (removeSession drops the reads).
        guard var read = subagentModelReads[sessionId]?[agentId] else { return }
        read.inFlight = false
        read.transcriptPath = transcriptPath ?? read.transcriptPath
        guard let observation else {
            let backoff = Self.subagentModelReadRetryInterval * pow(2, Double(max(0, read.attempts - 1)))
            read.retryAt = Date().addingTimeInterval(min(backoff, Self.subagentModelReadMaxRetryInterval))
            subagentModelReads[sessionId]?[agentId] = read
            return
        }
        subagentModelObservations[sessionId, default: [:]][agentId] = observation
        subagentModelReads[sessionId]?.removeValue(forKey: agentId)
        applySubagentModel(observation, sessionId: sessionId, agentId: agentId)
    }

    private func applySubagentModel(_ observation: ModelObservation, sessionId: String, agentId: String) {
        guard var subagent = sessions[sessionId]?.subagents[agentId] else { return }
        // A model the child's own hook reported is at least as current as the
        // cached transcript read, so only fill gaps.
        let model = subagent.model ?? observation.model
        let effort = subagent.reasoningEffort ?? observation.effort
        guard model != subagent.model || effort != subagent.reasoningEffort else { return }
        subagent.model = model
        subagent.reasoningEffort = effort
        sessions[sessionId]?.subagents[agentId] = subagent
    }

    /// Read a subagent's model/effort. Blocking file I/O: off the main actor.
    nonisolated static func readSubagentModel(
        from source: SubagentModelSource
    ) -> (observation: ModelObservation?, transcriptPath: String?) {
        switch source {
        case let .claude(parentTranscriptPath, agentId, knownPath):
            let path = knownPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                ?? claudeSubagentTranscriptPath(parentTranscriptPath: parentTranscriptPath, agentId: agentId)
            return (path.flatMap { readClaudeSubagentModel(atPath: $0) }, path)
        case let .codexRollout(path):
            return (ModelObservation.latestCodexTurnContext(path: path), nil)
        }
    }

    /// Newest model/effort in a Claude subagent's transcript.
    nonisolated static func readClaudeSubagentModel(
        parentTranscriptPath: String,
        agentId: String,
        maxBytes: Int = 64 * 1024
    ) -> ModelObservation? {
        claudeSubagentTranscriptPath(parentTranscriptPath: parentTranscriptPath, agentId: agentId)
            .flatMap { readClaudeSubagentModel(atPath: $0, maxBytes: maxBytes) }
    }

    nonisolated static func readClaudeSubagentModel(atPath path: String, maxBytes: Int = 64 * 1024) -> ModelObservation? {
        readTranscriptTailData(path: path, maxBytes: maxBytes).flatMap(ModelObservation.latestInClaudeTranscript)
    }

    /// A Claude subagent's transcript file. Plain subagents sit at
    /// `<session>/subagents/agent-<id>.jsonl`; grouped runs nest them one or
    /// two directories deeper — workflow agents live at
    /// `subagents/workflows/wf_<run>/agent-<id>.jsonl`.
    nonisolated static func claudeSubagentTranscriptPath(parentTranscriptPath: String, agentId: String) -> String? {
        guard let defaultPath = SubagentState.claudeTranscriptPath(
            parentTranscriptPath: parentTranscriptPath,
            agentId: agentId
        ) else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: defaultPath) { return defaultPath }
        let subagentsDir = (defaultPath as NSString).deletingLastPathComponent
        let fileName = (defaultPath as NSString).lastPathComponent
        func subdirectories(of dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }
                .map { "\(dir)/\($0)" }
        }
        for group in subdirectories(of: subagentsDir) {
            let candidate = "\(group)/\(fileName)"
            if fm.fileExists(atPath: candidate) { return candidate }
            for run in subdirectories(of: group) {
                let nested = "\(run)/\(fileName)"
                if fm.fileExists(atPath: nested) { return nested }
            }
        }
        return nil
    }

    private nonisolated static func readTranscriptTailData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}
