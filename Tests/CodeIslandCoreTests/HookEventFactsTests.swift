import XCTest
@testable import CodeIslandCore

/// The reducer reports what a hook event did (`HookEventFacts`); whether the
/// user hears about it is `AttentionPolicy`'s call. These pin the report.
final class HookEventFactsTests: XCTestCase {
    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    @discardableResult
    private func reduce(
        _ payload: [String: Any],
        _ sessions: inout [String: SessionSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HookEventReduction {
        reduceHookEvent(sessions: &sessions, event: try hookEvent(payload, file: file, line: line), maxHistory: 20)
    }

    private func isAttention(_ effect: SideEffect) -> Bool {
        switch effect {
        case .playSound, .enqueueCompletion: return true
        case .tryMonitorSession, .stopMonitor, .removeSession, .setActiveSession: return false
        }
    }

    /// The reducer never decides attention: a session's whole life, from a
    /// handful of agents, yields lifecycle effects only.
    func testReducerNeverEmitsAttentionEffects() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let lives: [[[String: Any]]] = [
            [
                ["hook_event_name": "SessionStart", "session_id": "claude", "cwd": "/repo"],
                ["hook_event_name": "UserPromptSubmit", "session_id": "claude", "prompt": "fix it"],
                ["hook_event_name": "PreToolUse", "session_id": "claude", "tool_name": "Bash"],
                ["hook_event_name": "PostToolUseFailure", "session_id": "claude", "tool_name": "Bash"],
                ["hook_event_name": "SubagentStart", "session_id": "claude", "agent_id": "a1", "agent_type": "Explore"],
                ["hook_event_name": "PreToolUse", "session_id": "claude", "agent_id": "a1", "tool_name": "Read"],
                ["hook_event_name": "SubagentStop", "session_id": "claude", "agent_id": "a1"],
                ["hook_event_name": "Stop", "session_id": "claude", "last_assistant_message": "done"],
                ["hook_event_name": "StopFailure", "session_id": "claude", "error": "rate_limit"],
                ["hook_event_name": "SessionEnd", "session_id": "claude"],
            ],
            [
                ["hook_event_name": "beforeSubmitPrompt", "session_id": "cursor", "_source": "cursor", "prompt": "hi"],
                ["hook_event_name": "afterAgentResponse", "session_id": "cursor", "_source": "cursor", "text": "hello"],
            ],
            [
                ["hook_event_name": "TaskStart", "session_id": "cline", "_source": "cline"],
                ["hook_event_name": "TaskComplete", "session_id": "cline", "_source": "cline"],
                ["hook_event_name": "PreToolUse", "session_id": "cline", "_source": "cline", "tool_name": "x"],
            ],
            [
                ["hook_event_name": "UserPromptSubmit", "session_id": "codex", "_source": "codex", "prompt": "go"],
                ["hook_event_name": "Interrupt", "session_id": "codex", "_source": "codex"],
                ["hook_event_name": "PostToolUse", "session_id": "codex", "_source": "codex", "tool_name": "shell"],
            ],
        ]
        for life in lives {
            for payload in life {
                let reduction = try reduce(payload, &sessions)
                XCTAssertFalse(reduction.effects.contains(where: isAttention), "\(payload["hook_event_name"] ?? ""): \(reduction.effects)")
            }
        }
    }

    func testAnOrdinaryEventMovesTheSession() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let facts = try reduce(["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "hi"], &sessions).facts
        XCTAssertEqual(facts, HookEventFacts(rawEventName: "UserPromptSubmit", appliedToSession: true))
    }

    func testATurnEndIsReported() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let stop = try reduce(["hook_event_name": "Stop", "session_id": "s"], &sessions).facts
        XCTAssertTrue(stop.appliedToSession)
        XCTAssertTrue(stop.endedTurn)
        XCTAssertNil(stop.turnError)

        let failure = try reduce(["hook_event_name": "StopFailure", "session_id": "s", "error": "rate_limit"], &sessions).facts
        XCTAssertEqual(failure.eventName, "Stop")
        XCTAssertTrue(failure.endedTurn)
        XCTAssertEqual(failure.turnError, PushSessionError(type: "rate_limit", detail: nil))

        let interrupt = try reduce(["hook_event_name": "Interrupt", "session_id": "codex", "_source": "codex"], &sessions).facts
        XCTAssertTrue(interrupt.endedTurn)
        XCTAssertTrue(sessions["codex"]?.interrupted == true)

        let cline = try reduce(["hook_event_name": "TaskComplete", "session_id": "cline", "_source": "cline"], &sessions).facts
        XCTAssertTrue(cline.endedTurn)

        let cursor = try reduce(["hook_event_name": "afterAgentResponse", "session_id": "cursor", "_source": "cursor", "text": "done"], &sessions).facts
        XCTAssertTrue(cursor.endedTurn)
    }

    /// A parent's Stop while one of its subagents still works keeps the card
    /// running: the turn has not ended yet.
    func testAStopWithASubagentStillWorkingEndsNoTurn() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try reduce(["hook_event_name": "SubagentStart", "session_id": "p", "agent_id": "a1"], &sessions)
        let facts = try reduce(["hook_event_name": "Stop", "session_id": "p"], &sessions).facts
        XCTAssertTrue(facts.appliedToSession)
        XCTAssertFalse(facts.endedTurn)
    }

    func testEventsThatDoNotMoveTheSessionItself() throws {
        var sessions: [String: SessionSnapshot] = [:]
        // Filed under a subagent.
        let subagent = try reduce(["hook_event_name": "PreToolUse", "session_id": "p", "agent_id": "a1", "tool_name": "Read"], &sessions).facts
        XCTAssertFalse(subagent.appliedToSession)

        // The end of the session.
        let end = try reduce(["hook_event_name": "SessionEnd", "session_id": "p"], &sessions)
        XCTAssertFalse(end.facts.appliedToSession)
        XCTAssertEqual(end.effects, [.removeSession(sessionId: "p")])

        // A Cline round already over: late tool hooks are stale.
        try reduce(["hook_event_name": "TaskComplete", "session_id": "cline", "_source": "cline"], &sessions)
        let stale = try reduce(["hook_event_name": "PreToolUse", "session_id": "cline", "_source": "cline", "tool_name": "x"], &sessions).facts
        XCTAssertFalse(stale.appliedToSession)

        // A Codex turn the user interrupted: queued tool hooks flush afterwards.
        try reduce(["hook_event_name": "Interrupt", "session_id": "codex", "_source": "codex"], &sessions)
        let flushed = try reduce(["hook_event_name": "PostToolUse", "session_id": "codex", "_source": "codex"], &sessions).facts
        XCTAssertFalse(flushed.appliedToSession)

        // A Hermes delegate_task child's only turn ending is its card ending.
        let oneShot = try reduce([
            "hook_event_name": "on_session_end", "session_id": "hermes-child", "_source": "hermes",
            "extra": ["platform": "subagent", "completed": true],
        ], &sessions)
        XCTAssertFalse(oneShot.facts.appliedToSession)
        XCTAssertFalse(oneShot.facts.endedTurn)
        XCTAssertEqual(oneShot.effects, [.removeSession(sessionId: "hermes-child")])
    }

    func testAConversationHeldElsewhereIsReported() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let telegram = try reduce([
            "hook_event_name": "on_session_end", "session_id": "gw", "_source": "hermes",
            "extra": ["platform": "telegram", "completed": true],
        ], &sessions).facts
        XCTAssertTrue(telegram.heldElsewhere)
        XCTAssertTrue(telegram.endedTurn, "the turn did end; the policy keeps it quiet")

        let cli = try reduce([
            "hook_event_name": "on_session_end", "session_id": "local", "_source": "hermes",
            "extra": ["platform": "cli", "completed": true],
        ], &sessions).facts
        XCTAssertFalse(cli.heldElsewhere)
    }

    func testASubagentsTurnEndIsReportedAsSuch() throws {
        var sessions: [String: SessionSnapshot] = [:]
        // A Cursor Task on a card of its own: its transcript names its chat.
        let chat = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let child = try reduce([
            "hook_event_name": "Stop", "session_id": "2528cb91-6379-48f2-aff8-40f4b804dafa", "_source": "cursor",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/\(chat)/\(chat).jsonl",
        ], &sessions).facts
        XCTAssertTrue(child.endedTurn)
        XCTAssertTrue(child.subagentTurn)

        let parent = try reduce(["hook_event_name": "Stop", "session_id": "main-thread", "_source": "codex"], &sessions).facts
        XCTAssertFalse(parent.subagentTurn)
    }

    /// `reduceEvent` returns what the reducer always did, in the same order:
    /// the completion where the turn ended, ahead of the monitor effect, and
    /// the sound after it.
    func testReduceEventKeepsTheOldEffectOrder() throws {
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: try hookEvent(
            ["hook_event_name": "UserPromptSubmit", "session_id": "s", "cwd": "/tmp/r", "prompt": "go"]
        ), maxHistory: 20)
        let effects = reduceEvent(sessions: &sessions, event: try hookEvent(
            ["hook_event_name": "Stop", "session_id": "s", "cwd": "/tmp/r", "last_assistant_message": "x"]
        ), maxHistory: 20)
        XCTAssertEqual(effects, [
            .enqueueCompletion(sessionId: "s"),
            .tryMonitorSession(sessionId: "s"),
            .playSound("Stop"),
        ])

        let prompt = reduceEvent(sessions: &sessions, event: try hookEvent(
            ["hook_event_name": "UserPromptSubmit", "session_id": "s", "cwd": "/tmp/r", "prompt": "again"]
        ), maxHistory: 20)
        XCTAssertEqual(prompt, [
            .tryMonitorSession(sessionId: "s"),
            .playSound("UserPromptSubmit"),
            .setActiveSession(sessionId: "s"),
        ])
    }

    /// `reduceEvent` is the reducer plus the policy's own reading of the
    /// event, as the reducer's tests have always seen it.
    func testReduceEventAddsThePolicysIntents() throws {
        var viaFacts: [String: SessionSnapshot] = [:]
        var composed: [String: SessionSnapshot] = [:]
        let payloads: [[String: Any]] = [
            ["hook_event_name": "SessionStart", "session_id": "s", "cwd": "/repo"],
            ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "go"],
            ["hook_event_name": "PostToolUseFailure", "session_id": "s", "tool_name": "Bash"],
            ["hook_event_name": "TaskComplete", "session_id": "s"],
            ["hook_event_name": "Stop", "session_id": "s"],
        ]
        for payload in payloads {
            let event = try hookEvent(payload)
            let reduction = reduceHookEvent(sessions: &viaFacts, event: event, maxHistory: 20)
            let intents = AttentionPolicy.intents(for: .hookEvent(reduction.facts), subject: AttentionSubject(viaFacts["s"]))
            let effects = reduceEvent(sessions: &composed, event: event, maxHistory: 20)

            XCTAssertEqual(effects.filter { !isAttention($0) }, reduction.effects)
            XCTAssertEqual(effects.contains(.enqueueCompletion(sessionId: "s")), intents.completion != nil)
            XCTAssertEqual(effects.compactMap { effect -> String? in
                if case .playSound(let cue) = effect { return cue }
                return nil
            }, intents.sound.map { [$0] } ?? [])
            if case .setActiveSession? = reduction.effects.last {
                XCTAssertEqual(effects.last, reduction.effects.last, "the active-session switch still closes the list")
            }
        }
    }
}
