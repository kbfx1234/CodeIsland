import XCTest
@testable import CodeIslandCore

/// The error jingle means "a whole turn died". A single failed tool call is
/// routine and must stay silent; Claude Code's `StopFailure` (and Grok's) is
/// the turn-level signal that owns the sound.
final class TurnFailureSoundTests: XCTestCase {
    private func hookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    private func sounds(_ effects: [SideEffect]) -> [String] {
        effects.compactMap {
            if case .playSound(let name) = $0 { return name }
            return nil
        }
    }

    // MARK: - Routing

    func testToolFailureIsSilent() {
        XCTAssertNil(EventSoundRouting.soundEvent(
            rawEventName: "PostToolUseFailure", normalizedEventName: "PostToolUseFailure"))
        // Traecli / Kimi spell it snake_case; it normalizes to the same thing.
        XCTAssertNil(EventSoundRouting.soundEvent(
            rawEventName: "post_tool_use_failure",
            normalizedEventName: EventNormalizer.normalize("post_tool_use_failure")))
    }

    func testStopFailureRoutesToTurnFailedInBothSpellings() {
        for raw in ["StopFailure", "stop_failure"] {
            XCTAssertEqual(
                EventSoundRouting.soundEvent(rawEventName: raw, normalizedEventName: EventNormalizer.normalize(raw)),
                EventSoundRouting.turnFailed,
                raw
            )
        }
    }

    func testOrdinaryEventsKeepTheirNormalizedSound() {
        XCTAssertEqual(EventSoundRouting.soundEvent(rawEventName: "Stop", normalizedEventName: "Stop"), "Stop")
        XCTAssertEqual(
            EventSoundRouting.soundEvent(rawEventName: "stop", normalizedEventName: EventNormalizer.normalize("stop")),
            "Stop"
        )
        XCTAssertEqual(
            EventSoundRouting.soundEvent(rawEventName: "UserPromptSubmit", normalizedEventName: "UserPromptSubmit"),
            "UserPromptSubmit"
        )
    }

    // MARK: - Reducer

    func testReducerDoesNotRingForAFailedTool() throws {
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash",
        ]), maxHistory: 20)
        let effects = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "PostToolUseFailure", "session_id": "s1", "tool_name": "Bash",
        ]), maxHistory: 20)

        XCTAssertEqual(sounds(effects), [])
        // Still recorded as a failed tool and the turn keeps going.
        XCTAssertEqual(sessions["s1"]?.toolHistory.last?.success, false)
        XCTAssertEqual(sessions["s1"]?.status, .processing)
    }

    func testStopFailureEndsTheTurnAndRingsTurnFailed() throws {
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "UserPromptSubmit", "session_id": "s2", "prompt": "go",
        ]), maxHistory: 20)
        let effects = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "StopFailure",
            "session_id": "s2",
            "error_type": "rate_limit",
            "error": "Rate limit exceeded",
            "last_assistant_message": "I'll start by…",
        ]), maxHistory: 20)

        XCTAssertEqual(sounds(effects), [EventSoundRouting.turnFailed])
        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s2")))
        XCTAssertEqual(sessions["s2"]?.status, .idle)
        XCTAssertEqual(sessions["s2"]?.lastAssistantMessage, "I'll start by…")
    }

    func testPlainStopStillRingsCompletion() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let effects = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "Stop", "session_id": "s3",
        ]), maxHistory: 20)
        XCTAssertEqual(sounds(effects), ["Stop"])
    }

    // MARK: - Debounce

    func testDebouncerRingsOncePerBurstPerKey() {
        var debouncer = SoundDebouncer(window: 60)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(debouncer.shouldPlay(key: "a", now: t0))
        XCTAssertFalse(debouncer.shouldPlay(key: "a", now: t0.addingTimeInterval(5)))
        // Another session's failure is its own news.
        XCTAssertTrue(debouncer.shouldPlay(key: "b", now: t0.addingTimeInterval(6)))
    }

    func testDebounceWindowSlidesWhileFailuresKeepComing() {
        var debouncer = SoundDebouncer(window: 60)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(debouncer.shouldPlay(key: "a", now: t0))
        // Each retry fails within the window of the previous one: still one burst.
        XCTAssertFalse(debouncer.shouldPlay(key: "a", now: t0.addingTimeInterval(50)))
        XCTAssertFalse(debouncer.shouldPlay(key: "a", now: t0.addingTimeInterval(100)))
        // A full quiet minute later it is a new failure again.
        XCTAssertTrue(debouncer.shouldPlay(key: "a", now: t0.addingTimeInterval(161)))
    }
}
