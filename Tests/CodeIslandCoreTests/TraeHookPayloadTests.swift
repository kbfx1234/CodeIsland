import XCTest
@testable import CodeIslandCore

/// #341 — TRAE's desktop IDE puts `agent_id` (the agent RUNNING the hook) on
/// every event, main conversation included: `solo_agent` for Trae CN's
/// built-in agent, other built-in names or a custom agent's id otherwise.
/// Read as a Claude-style subagent marker, the conversation was folded into
/// `subagents`, its first Stop tombstoned the id, and every later turn was
/// dropped.
final class TraeHookPayloadTests: XCTestCase {
    @discardableResult
    private func apply(
        _ payload: [String: Any],
        to sessions: inout [String: SessionSnapshot]
    ) throws -> [SideEffect] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))
        return reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
    }

    private func payload(
        _ event: String,
        source: String,
        sessionId: String,
        agentId: String,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var json: [String: Any] = [
            "hook_event_name": event,
            "session_id": sessionId,
            "_source": source,
            "cwd": "/Users/dev/project",
            "workspace_roots": ["/Users/dev/project"],
            "agent_id": agentId,
            "agent_type": "agent",
        ]
        json.merge(extra) { _, new in new }
        return json
    }

    private func assertMainConversationSurvivesSecondTurn(
        source: String,
        agentId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sessionId = "trae-\(source)-\(agentId)"
        var sessions: [String: SessionSnapshot] = [:]
        func send(_ event: String, _ extra: [String: Any] = [:]) throws -> [SideEffect] {
            try apply(payload(event, source: source, sessionId: sessionId, agentId: agentId, extra: extra), to: &sessions)
        }

        try send("SessionStart", ["source": "startup"])
        XCTAssertEqual(sessions[sessionId]?.source, source, file: file, line: line)

        try send("UserPromptSubmit", ["prompt": "first task"])
        XCTAssertEqual(sessions[sessionId]?.status, .processing, file: file, line: line)
        XCTAssertEqual(sessions[sessionId]?.lastUserPrompt, "first task", file: file, line: line)

        try send("PreToolUse", ["tool_name": "RunCommand", "tool_use_id": "t1", "tool_input": ["command": "ls"]])
        XCTAssertEqual(sessions[sessionId]?.status, .running, file: file, line: line)
        XCTAssertEqual(sessions[sessionId]?.currentTool, "RunCommand", file: file, line: line)

        try send("PostToolUse", ["tool_name": "RunCommand", "tool_use_id": "t1"])
        let stopEffects = try send("Stop", ["stop_hook_active": false, "loop_count": 0, "last_assistant_message": "done"])
        XCTAssertEqual(sessions[sessionId]?.status, .idle, file: file, line: line)
        XCTAssertTrue(stopEffects.contains(.enqueueCompletion(sessionId: sessionId)), file: file, line: line)
        XCTAssertTrue(sessions[sessionId]?.subagents.isEmpty ?? false, file: file, line: line)
        XCTAssertFalse(sessions[sessionId]?.hasClosedSubagentId(agentId) ?? true, file: file, line: line)

        // The regression: the second turn used to be swallowed by the
        // tombstoned "subagent".
        try send("UserPromptSubmit", ["prompt": "second task"])
        XCTAssertEqual(sessions[sessionId]?.status, .processing, file: file, line: line)
        XCTAssertEqual(sessions[sessionId]?.lastUserPrompt, "second task", file: file, line: line)
    }

    func testTraeCNSoloAgentIsTheMainConversation() throws {
        try assertMainConversationSurvivesSecondTurn(source: "traecn", agentId: "solo_agent")
    }

    /// Same runtime in the international edition, and any agent the user picks
    /// (built-in or custom) is the main conversation — not just `solo_agent`.
    func testAnyTraeAgentIdIsTheMainConversation() throws {
        try assertMainConversationSurvivesSecondTurn(source: "trae", agentId: "solo_agent")
        try assertMainConversationSurvivesSecondTurn(source: "traecn", agentId: "builder_v3")
        try assertMainConversationSurvivesSecondTurn(source: "trae", agentId: "my-custom-agent")
    }

    func testOnlyTraeIDESourcesDropTheAgentId() throws {
        func agentId(source: String?) throws -> String? {
            var json: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": "s", "agent_id": "a1"]
            if let source { json["_source"] = source }
            let data = try JSONSerialization.data(withJSONObject: json)
            return try XCTUnwrap(HookEvent(from: data)).agentId
        }
        XCTAssertNil(try agentId(source: "trae"))
        XCTAssertNil(try agentId(source: "traecn"))
        XCTAssertNil(try agentId(source: "trae-cn"))
        // Claude-style subagent routing is untouched everywhere else.
        XCTAssertEqual(try agentId(source: "claude"), "a1")
        XCTAssertEqual(try agentId(source: "traecli"), "a1")
        XCTAssertEqual(try agentId(source: nil), "a1")
    }
}
