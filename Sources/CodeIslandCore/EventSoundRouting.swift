import Foundation

/// Which sound, if any, a hook event rings — the cue `AttentionPolicy` reads
/// for a hook event before its other rules and the user's settings apply.
///
/// Sounds mark turn boundaries, not steps inside a turn. A failed tool call —
/// a Bash command exiting non-zero, an Edit whose `old_string` did not match —
/// is routine: the agent reads the error and carries on. Ringing the "task
/// error" jingle for every one of them taught users to tune out the sound that
/// should mean "this turn died and needs you".
public enum EventSoundRouting {
    /// Sound event for a turn that ended on an error rather than a reply:
    /// Claude Code / Grok `StopFailure` (rate limit, overload, auth, billing…)
    /// and AiWork's `stream.failed`. The name follows Claude Code's hook.
    public static let turnFailed = "StopFailure"

    /// The sound event for a hook, or nil when it should stay silent.
    ///
    /// Takes the raw wire name as well as the normalized one because
    /// `EventNormalizer` folds `StopFailure` onto `Stop` — the island state
    /// really is "turn over" either way — and the failure is only visible
    /// before that fold.
    public static func soundEvent(rawEventName: String, normalizedEventName: String) -> String? {
        if normalizedEventName == "PostToolUseFailure" { return nil }
        // The launch chime's cue is the app's own: a hook event that happens
        // to carry its name rings nothing.
        if normalizedEventName == SoundCue.launch { return nil }
        if rawEventName == "StopFailure" || rawEventName == "stop_failure" { return turnFailed }
        return normalizedEventName
    }
}

/// "Ring at most once per burst", per key.
///
/// The window slides with every hit, suppressed or not: a rate-limited session
/// that the user keeps retrying fails the same way every few seconds, and one
/// error jingle already said everything the next ten would. Only a failure
/// arriving after a full quiet window counts as news again.
public struct SoundDebouncer: Sendable {
    public let window: TimeInterval
    private var lastHit: [String: Date] = [:]

    public init(window: TimeInterval) {
        self.window = window
    }

    public mutating func shouldPlay(key: String, now: Date) -> Bool {
        let previous = lastHit[key]
        // Forget keys whose window has closed so a long-running app does not
        // keep one entry per session it ever saw fail.
        lastHit = lastHit.filter { now.timeIntervalSince($0.value) < window }
        lastHit[key] = now
        guard let previous else { return true }
        return now.timeIntervalSince(previous) >= window
    }
}
