import Foundation
@testable import CodeIslandCore

/// A ``SubsessionContext`` without AppState: the cards a test sets up, and
/// the Codex rollouts it says exist (counting how often each is asked for).
final class StubSubsessionContext: SubsessionContext {
    var cards: [String: SessionSnapshot]
    /// Rollout answers by transcript path; any other path is unreadable.
    var rollouts: [String: CodexTranscriptSubagentInspection]
    private(set) var rolloutQueries: [String] = []

    init(
        cards: [String: SessionSnapshot] = [:],
        rollouts: [String: CodexTranscriptSubagentInspection] = [:]
    ) {
        self.cards = cards
        self.rollouts = rollouts
    }

    func codexRolloutInspection(transcriptPath: String) -> CodexTranscriptSubagentInspection {
        rolloutQueries.append(transcriptPath)
        return rollouts[transcriptPath] ?? .unavailable
    }
}

/// A card for the subsession tests.
func subsessionCard(
    source: String,
    status: AgentStatus = .processing,
    providerSessionId: String? = nil,
    transcriptPath: String? = nil,
    cliPid: pid_t? = nil,
    termBundleId: String? = nil,
    lastActivity: Date = Date(),
    startTime: Date = Date()
) -> SessionSnapshot {
    var card = SessionSnapshot(startTime: startTime)
    card.source = source
    card.status = status
    card.providerSessionId = providerSessionId
    card.transcriptPath = transcriptPath
    card.cliPid = cliPid
    card.termBundleId = termBundleId
    card.lastActivity = lastActivity
    return card
}
