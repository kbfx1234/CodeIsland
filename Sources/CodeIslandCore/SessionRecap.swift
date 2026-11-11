import Foundation

/// Claude Code's "while you were away" recap.
///
/// A few minutes after a turn goes idle Claude Code appends
/// `{"type":"system","subtype":"away_summary","content":"…","timestamp":"…"}`
/// to the transcript: one or two sentences on what got done and what is
/// waiting on the user. The island shows it on idle cards until a newer user
/// prompt starts another turn, at which point it no longer describes where the
/// session stands.
public struct SessionRecap: Equatable, Sendable, Codable {
    public let text: String
    /// When Claude Code wrote the recap (the line's `timestamp`), falling back
    /// to the moment it was observed.
    public let createdAt: Date

    public init(text: String, createdAt: Date) {
        self.text = text
        self.createdAt = createdAt
    }

    /// A prompt submitted at or after the recap was written starts a new turn.
    public func isSuperseded(byPromptAt promptAt: Date) -> Bool {
        promptAt >= createdAt
    }

    /// Build from a parsed transcript line, or nil when it is not a usable
    /// main-thread `away_summary`.
    public static func from(transcriptLine json: [String: Any], observedAt: Date = Date()) -> SessionRecap? {
        guard json["subtype"] as? String == "away_summary",
              json["isSidechain"] as? Bool != true,
              let text = cleanedText(json["content"]) else { return nil }
        let createdAt = (json["timestamp"] as? String).flatMap(ClaudeUsageScanner.parseISO8601) ?? observedAt
        return SessionRecap(text: text, createdAt: createdAt)
    }

    /// Trim the raw `content` and drop the "(disable recaps in /config)" hint
    /// the CLI appends for its own TUI — an instruction for the terminal, not
    /// part of the summary. Matched on "/config" inside a trailing
    /// parenthetical so other CLI languages/wordings are covered too.
    public static func cleanedText(_ raw: Any?) -> String? {
        guard var text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.hasSuffix(")"),
           let open = text.range(of: "(", options: .backwards),
           text[open.lowerBound...].contains("/config") {
            text = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}

extension SessionSnapshot {
    /// A new user prompt makes an older recap stale.
    public mutating func clearRecapIfSuperseded(byPromptAt promptAt: Date) {
        if let recap, recap.isSuperseded(byPromptAt: promptAt) {
            self.recap = nil
        }
    }

    /// Apply the recap / model fields of a live transcript tail delta.
    ///
    /// Returns true when anything changed. Deliberately leaves `lastActivity`
    /// alone: a recap lands minutes after the turn ended and is not agent
    /// activity, so it must not reorder cards or postpone idle cleanup.
    public mutating func applyTranscriptMetadata(from delta: ConversationTailDelta) -> Bool {
        applyTranscriptMetadata(
            recap: delta.sessionRecap,
            sawUserPrompt: delta.lastUserPrompt != nil,
            modelObservation: delta.modelObservation,
            longContextSwitch: delta.configuredLongContext,
            isBackfill: false
        )
    }

    /// Attach-time backfill from a scan of the transcript's tail.
    ///
    /// The scan is authoritative for the recap: a fresh recap is always within
    /// the tail (only small bookkeeping lines follow one until the next prompt),
    /// so "no recap in the tail" means a restored/persisted recap went stale
    /// while nobody was watching. It is *not* authoritative for a model a hook
    /// reported after the scanned lines were written (see
    /// ``applyBackfilledModelObservation(_:)``).
    public mutating func applyTranscriptBackfill(_ scan: JSONLTailer.ScanResult.Delta) -> Bool {
        applyTranscriptMetadata(
            recap: scan.sessionRecap,
            sawUserPrompt: scan.lastUserPrompt != nil,
            modelObservation: scan.modelObservation,
            longContextSwitch: scan.configuredLongContext,
            isBackfill: true
        )
    }

    /// A model/effort read from transcript history (not a live line): it
    /// yields to a model a hook reported after that line was written —
    /// `claude --resume --model X` over a transcript that ran on Y keeps X,
    /// and takes the line's effort only when the line was on X too.
    public mutating func applyBackfilledModelObservation(_ observation: ModelObservation) -> Bool {
        applyModelObservation(observation, isBackfill: true)
    }

    private mutating func applyTranscriptMetadata(
        recap newRecap: SessionRecap?,
        sawUserPrompt: Bool,
        modelObservation: ModelObservation?,
        longContextSwitch: Bool?,
        isBackfill: Bool
    ) -> Bool {
        var changed = false
        // The scan only reports a recap that no later prompt in the same chunk
        // superseded, and every line in the chunk postdates what we already
        // hold — so a prompt clears the old recap and a chunk recap replaces it.
        let resolvedRecap: SessionRecap?
        if let newRecap {
            resolvedRecap = newRecap
        } else if sawUserPrompt || isBackfill {
            resolvedRecap = nil
        } else {
            resolvedRecap = recap
        }
        if resolvedRecap != recap {
            recap = resolvedRecap
            changed = true
        }

        // A `/model` switch to or from the 1M variant. From history, only while
        // no hook has reported the model since: that report is newer.
        if let longContextSwitch, !(isBackfill && modelReportedAt != nil) {
            configuredLongContext = longContextSwitch
            if let current = model {
                let switched = ModelLabel.withLongContext(current, longContextSwitch)
                if switched != current {
                    model = switched
                    changed = true
                }
            }
        }

        if let modelObservation, applyModelObservation(modelObservation, isBackfill: isBackfill) {
            changed = true
        }
        return changed
    }

    private mutating func applyModelObservation(_ observation: ModelObservation, isBackfill: Bool) -> Bool {
        if isBackfill, let reportedAt = modelReportedAt,
           (observation.observedAt ?? .distantPast) < reportedAt {
            guard ModelLabel.isSameModel(current: model, observed: observation.model),
                  observation.effort != reasoningEffort else { return false }
            reasoningEffort = observation.effort
            return true
        }
        var changed = false
        // Transcript lines carry the bare API id; after a `/model` switch its
        // word on the 1M variant decides the decoration, otherwise a
        // hook-reported `[1m]` id of the same model survives.
        let mergedModel = configuredLongContext.map { ModelLabel.withLongContext(observation.model, $0) }
            ?? ModelLabel.mergedModelId(current: model, observed: observation.model)
        if mergedModel != model {
            model = mergedModel
            changed = true
        }
        if observation.effort != reasoningEffort {
            reasoningEffort = observation.effort
            changed = true
        }
        return changed
    }

    /// Recap to show on the card: only while the session is idle — a working
    /// session's live output is more current than any summary of the past.
    public var visibleRecap: SessionRecap? {
        status == .idle ? recap : nil
    }

    /// "Opus 5.5 · xhigh" for the card's model tag.
    public var modelLabel: String? {
        ModelLabel.label(model: model, effort: reasoningEffort)
    }
}

extension SubagentState {
    /// A Claude subagent's own transcript, derived from the parent's:
    /// `<project>/<session>.jsonl` → `<project>/<session>/subagents/agent-<id>.jsonl`.
    /// Claude Code hooks never say which model a subagent runs, so this file is
    /// the only place its model (which may differ from the parent's) is recorded.
    public static func claudeTranscriptPath(parentTranscriptPath: String, agentId: String) -> String? {
        let suffix = ".jsonl"
        guard parentTranscriptPath.hasSuffix(suffix),
              !agentId.isEmpty, !agentId.contains("/"), !agentId.contains("..") else { return nil }
        let sessionDir = String(parentTranscriptPath.dropLast(suffix.count))
        return "\(sessionDir)/subagents/agent-\(agentId).jsonl"
    }

    /// Label for the subagent's own model, never the parent's.
    public var modelLabel: String? {
        ModelLabel.label(model: model, effort: reasoningEffort)
    }
}
