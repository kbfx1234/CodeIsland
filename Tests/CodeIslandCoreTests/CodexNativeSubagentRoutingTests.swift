import XCTest
@testable import CodeIslandCore

final class CodexNativeSubagentRoutingTests: XCTestCase {
    func testCodexSubagentSessionStartDoesNotResetParentSession() throws {
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.currentTool = "spawn_agent"
        parent.model = "gpt-5.4"
        parent.cwd = "/repo"
        parent.transcriptPath = "/tmp/parent.jsonl"

        var sessions = ["parent": parent]
        let event = try decode([
            "hook_event_name": "SessionStart",
            "session_id": "parent",
            "_source": "codex",
            "agent_id": "child",
            "agent_type": "default",
            "model": "gpt-5.4-mini",
            "cwd": "/repo",
            "transcript_path": "/tmp/child.jsonl",
        ])

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["parent"]?.model, "gpt-5.4")
        XCTAssertEqual(sessions["parent"]?.transcriptPath, "/tmp/parent.jsonl")
        XCTAssertEqual(sessions["parent"]?.subagents["child"]?.agentType, "default")
        XCTAssertEqual(sessions["parent"]?.status, .running)
        XCTAssertTrue(effects.contains(.setActiveSession(sessionId: "parent")))
    }

    func testCodexChildDoesNotLendItsRolloutToAParentWithoutOne() throws {
        // The parent's own hooks haven't named its rollout yet; the child's
        // transcript_path is the child's rollout, and tailing it as the
        // parent's labels the parent with the child's model and effort.
        var parent = SessionSnapshot()
        parent.source = "codex"
        var sessions = ["parent": parent]
        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "parent",
            "_source": "codex",
            "agent_id": "child",
            "agent_type": "worker",
            "tool_name": "exec_command",
            "transcript_path": "/tmp/child-rollout.jsonl",
        ]), maxHistory: 10)
        XCTAssertNil(sessions["parent"]?.transcriptPath)

        // Claude subagent hooks carry the parent's own transcript: still used.
        var claudeSessions = ["main": SessionSnapshot()]
        _ = reduceEvent(sessions: &claudeSessions, event: try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "main",
            "agent_id": "a1",
            "agent_type": "Explore",
            "tool_name": "Read",
            "transcript_path": "/tmp/main-session.jsonl",
        ]), maxHistory: 10)
        XCTAssertEqual(claudeSessions["main"]?.transcriptPath, "/tmp/main-session.jsonl")
    }

    func testCodexSubagentPromptAndStopAreConsumedByParentSubagentState() throws {
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.lastUserPrompt = "main prompt"
        parent.addRecentMessage(ChatMessage(isUser: true, text: "main prompt"))
        parent.subagents["child"] = SubagentState(agentId: "child", agentType: "default")

        var sessions = ["parent": parent]
        let promptEvent = try decode([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "parent",
            "_source": "codex",
            "agent_id": "child",
            "agent_type": "default",
            "prompt": "child task",
        ])
        _ = reduceEvent(sessions: &sessions, event: promptEvent, maxHistory: 10)

        XCTAssertEqual(sessions["parent"]?.lastUserPrompt, "main prompt")
        XCTAssertEqual(sessions["parent"]?.recentMessages.map(\.text), ["main prompt"])
        XCTAssertEqual(sessions["parent"]?.subagents["child"]?.status, .processing)

        let stopEvent = try decode([
            "hook_event_name": "Stop",
            "session_id": "parent",
            "_source": "codex",
            "agent_id": "child",
            "agent_type": "default",
        ])
        _ = reduceEvent(sessions: &sessions, event: stopEvent, maxHistory: 10)

        XCTAssertTrue(sessions["parent"]?.subagents.isEmpty == true)
        XCTAssertEqual(sessions["parent"]?.status, .processing)
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "CodexNativeSubagentRoutingTests", code: 1)
        }
        return event
    }
}
