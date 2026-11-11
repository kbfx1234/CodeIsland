import XCTest
@testable import CodeIslandCore

/// Remote tool steps no longer wait for the island's reply, so over SSH a
/// large PostToolUse(A) can arrive after the PreToolUse(B) that came next —
/// parallel tool calls in particular. A step that names a tool use other
/// than the running one must not take the running tool down; one that
/// names none goes as it always did.
final class OutOfOrderToolStepTests: XCTestCase {
    private var sessions: [String: SessionSnapshot] = [:]

    private func step(
        _ name: String,
        tool: String,
        id: String?,
        command: String,
        agent: String? = nil
    ) -> HookEvent {
        var json: [String: Any] = [
            "hook_event_name": name,
            "session_id": "s1",
            "tool_name": tool,
            "tool_input": ["command": command],
        ]
        if let id { json["tool_use_id"] = id }
        if let agent { json["agent_id"] = agent }
        return HookEvent(json: json)!
    }

    private func reduce(_ events: HookEvent...) {
        for event in events {
            _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
        }
    }

    override func setUp() {
        super.setUp()
        sessions = [:]
    }

    func testAnOvertakenPostLeavesTheRunningToolUp() {
        reduce(
            step("PreToolUse", tool: "Bash", id: "a", command: "make"),
            step("PreToolUse", tool: "Bash", id: "b", command: "make test"),
            step("PostToolUse", tool: "Bash", id: "a", command: "make")
        )
        XCTAssertEqual(sessions["s1"]?.status, .running, "the running tool was taken down")
        XCTAssertEqual(sessions["s1"]?.currentTool, "Bash")
        XCTAssertEqual(sessions["s1"]?.toolDescription, "make test")
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.description), ["make"], "the finished tool was not recorded as itself")
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.success), [true])

        reduce(step("PostToolUse", tool: "Bash", id: "b", command: "make test"))
        XCTAssertEqual(sessions["s1"]?.status, .processing)
        XCTAssertNil(sessions["s1"]?.currentTool)
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.description), ["make", "make test"])
    }

    func testAnOvertakenFailureLeavesTheRunningToolUp() {
        reduce(
            step("PreToolUse", tool: "Bash", id: "a", command: "make"),
            step("PreToolUse", tool: "Read", id: "b", command: "cat"),
            step("PostToolUseFailure", tool: "Bash", id: "a", command: "make")
        )
        XCTAssertEqual(sessions["s1"]?.status, .running, "the running tool was taken down")
        XCTAssertEqual(sessions["s1"]?.currentTool, "Read")
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.tool), ["Bash"])
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.success), [false])
    }

    /// A source that names no tool use: the step finishes whatever runs.
    func testStepsWithoutIdsGoAsBefore() {
        reduce(
            step("PreToolUse", tool: "Bash", id: nil, command: "make"),
            step("PreToolUse", tool: "Read", id: nil, command: "cat"),
            step("PostToolUse", tool: "Bash", id: nil, command: "make")
        )
        XCTAssertEqual(sessions["s1"]?.status, .processing)
        XCTAssertNil(sessions["s1"]?.currentTool)
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.tool), ["Read"])
    }

    /// Only one side naming its tool use is not enough to tell them apart.
    func testAStepNamingNoToolUseFinishesTheRunningOne() {
        reduce(
            step("PreToolUse", tool: "Bash", id: "a", command: "make"),
            step("PostToolUse", tool: "Bash", id: nil, command: "make")
        )
        XCTAssertEqual(sessions["s1"]?.status, .processing)
        XCTAssertNil(sessions["s1"]?.currentTool)
    }

    /// A tool put up by something other than its PreToolUse (here a
    /// subagent starting) no longer carries the earlier tool use's id.
    func testAnotherChangeOfTheRunningToolForgetsItsToolUse() {
        reduce(
            step("PreToolUse", tool: "Bash", id: "a", command: "make"),
            HookEvent(json: ["hook_event_name": "SubagentStart", "session_id": "s1", "agent_type": "Explore"])!
        )
        XCTAssertEqual(sessions["s1"]?.currentTool, "Agent")
        XCTAssertNil(sessions["s1"]?.currentToolUseId)
    }

    func testAnOvertakenSubagentPostLeavesItsRunningToolUp() {
        reduce(
            step("PreToolUse", tool: "Bash", id: "a", command: "make", agent: "sub-1"),
            step("PreToolUse", tool: "Bash", id: "b", command: "make test", agent: "sub-1"),
            step("PostToolUse", tool: "Bash", id: "a", command: "make", agent: "sub-1")
        )
        let subagent = sessions["s1"]?.subagents["sub-1"]
        XCTAssertEqual(subagent?.status, .running, "the subagent's running tool was taken down")
        XCTAssertEqual(subagent?.currentTool, "Bash")
        XCTAssertEqual(subagent?.toolDescription, "make test")
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.description), ["make"])

        reduce(step("PostToolUseFailure", tool: "Bash", id: "a", command: "make", agent: "sub-1"))
        XCTAssertEqual(sessions["s1"]?.subagents["sub-1"]?.currentTool, "Bash", "an overtaken failure took the tool down")

        reduce(step("PostToolUse", tool: "Bash", id: "b", command: "make test", agent: "sub-1"))
        XCTAssertEqual(sessions["s1"]?.subagents["sub-1"]?.status, .processing)
        XCTAssertNil(sessions["s1"]?.subagents["sub-1"]?.currentTool)
        XCTAssertEqual(sessions["s1"]?.toolHistory.map(\.description), ["make", "make", "make test"])
    }
}
