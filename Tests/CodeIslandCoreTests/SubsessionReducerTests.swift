import XCTest
@testable import CodeIslandCore

/// What the reducer does with a hook Agent Sub-Sessions routed: a child on a
/// card of its own is linked to its parent and stays quiet, whatever kind of
/// child it is; a child folded into its parent's card is a row marked as one.
final class SubsessionReducerTests: XCTestCase {
    private let parent = "parent-thread"
    private let child = "child-thread"

    private func apply(_ payload: [String: Any], to sessions: inout [String: SessionSnapshot]) throws -> [SideEffect] {
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        return reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
    }

    /// A child's hook as the router hands it over in Show separately.
    private func linked(_ event: String, source: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        [
            "hook_event_name": event, "session_id": child, "_source": source,
            SubsessionRouter.linkedParentKey: parent,
        ].merging(extra) { _, new in new }
    }

    /// A child's hook as the router hands it over in Merge.
    private func folded(_ event: String, kind: SubsessionLink.Kind, _ extra: [String: Any] = [:]) -> [String: Any] {
        var raw: [String: Any] = ["hook_event_name": event, "session_id": child, "_source": kind == .cursorTask ? "cursor" : "codex"]
        raw.merge(extra) { _, new in new }
        let link = SubsessionLink(kind: kind, childCardId: child, agentId: child, parentCardId: parent)
        XCTAssertTrue(SubsessionRouter.fold(&raw, link: link, into: parent))
        return raw
    }

    private func sounds(_ effects: [SideEffect]) -> [String] {
        effects.compactMap { if case .playSound(let name) = $0 { return name } else { return nil } }
    }

    private func completions(_ effects: [SideEffect]) -> [String] {
        effects.compactMap { if case .enqueueCompletion(let id) = $0 { return id } else { return nil } }
    }

    func testLinkedChildOfEveryKindStaysQuiet() throws {
        for source in ["codex", "cursor", "opencode", "pi"] {
            var sessions: [String: SessionSnapshot] = [:]
            var effects: [SideEffect] = []
            effects += try apply(linked("SessionStart", source: source), to: &sessions)
            effects += try apply(linked("UserPromptSubmit", source: source, ["prompt": "task"]), to: &sessions)
            effects += try apply(linked("PreToolUse", source: source, ["tool_name": "Bash"]), to: &sessions)
            effects += try apply(linked("Stop", source: source, ["last_assistant_message": "done"]), to: &sessions)
            XCTAssertEqual(sounds(effects), [], source)
            XCTAssertEqual(completions(effects), [], source)
            XCTAssertEqual(sessions[child]?.parentSessionId, parent, source)
            XCTAssertEqual(sessions[child]?.status, .idle, "\(source): its card still settles")
        }
    }

    func testLinkSurvivesTheSessionStartRebuild() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try apply(linked("UserPromptSubmit", source: "codex", ["prompt": "task"]), to: &sessions)
        try apply(linked("SessionStart", source: "codex"), to: &sessions)
        XCTAssertEqual(sessions[child]?.parentSessionId, parent)
        // A hook that says nothing never unlinks it: an AppState pass may
        // have made the link, which the child's hooks do not carry.
        try apply(["hook_event_name": "PreToolUse", "session_id": child, "_source": "codex"], to: &sessions)
        XCTAssertEqual(sessions[child]?.parentSessionId, parent)
        try apply(["hook_event_name": "SessionStart", "session_id": child, "_source": "codex"], to: &sessions)
        XCTAssertEqual(sessions[child]?.parentSessionId, parent)
        // One that names a parent wins.
        try apply(linked("SessionStart", source: "codex", [SubsessionRouter.linkedParentKey: "other-parent"]), to: &sessions)
        XCTAssertEqual(sessions[child]?.parentSessionId, "other-parent")
        // A card nobody linked stays unlinked.
        try apply(["hook_event_name": "SessionStart", "session_id": parent, "_source": "codex"], to: &sessions)
        XCTAssertNil(sessions[parent]?.parentSessionId)
    }

    /// A `_ppid` past pid_t's range comes only from a malformed payload. The
    /// router ignores it, and so does the reducer, where converting it
    /// trapped: on SessionStart, on every other hook, and on a subagent's
    /// hook filling in its parent's process.
    func testProcessIdOutsidePidRangeIsIgnored() throws {
        var sessions: [String: SessionSnapshot] = [:]
        for event in ["SessionStart", "PreToolUse"] {
            try apply(["hook_event_name": event, "session_id": parent, "_source": "codex", "_ppid": 9_999_999_999], to: &sessions)
            XCTAssertNil(sessions[parent]?.cliPid, event)
        }
        try apply([
            "hook_event_name": "PreToolUse", "session_id": parent, "_source": "claude",
            "agent_id": child, "_ppid": 9_999_999_999,
        ], to: &sessions)
        XCTAssertNil(sessions[parent]?.cliPid)
        try apply(["hook_event_name": "PreToolUse", "session_id": parent, "_source": "codex", "_ppid": 4242], to: &sessions)
        XCTAssertEqual(sessions[parent]?.cliPid, 4242)
    }

    func testChildWhoseHooksNameItselfAsAgentIsStillLinked() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try apply(linked("PreToolUse", source: "codex", ["agent_id": child, "tool_name": "exec_command"]), to: &sessions)
        XCTAssertEqual(sessions[child]?.parentSessionId, parent)
    }

    func testFoldedChildRowIsMarkedAndAnAgentsOwnSubagentIsNot() throws {
        var sessions: [String: SessionSnapshot] = [parent: SessionSnapshot()]
        sessions[parent]?.source = "codex"
        try apply(folded("PreToolUse", kind: .codexThread, ["tool_name": "exec_command"]), to: &sessions)
        XCTAssertEqual(sessions[parent]?.subagents[child]?.subsessionKind, .codexThread)
        XCTAssertNil(sessions[parent]?.parentSessionId, "the host card is nobody's child")

        try apply([
            "hook_event_name": "SubagentStart", "session_id": parent, "_source": "codex",
            "agent_id": "own-agent", "agent_type": "worker",
        ], to: &sessions)
        XCTAssertNotNil(sessions[parent]?.subagents["own-agent"])
        XCTAssertNil(sessions[parent]?.subagents["own-agent"]?.subsessionKind)
    }

    /// Every folded child starts a turn with a prompt and none sends a
    /// SubagentStart: a prompt after its Stop is its next turn. A Codex thread
    /// folded into its parent used to lose every turn after its first.
    func testFoldedChildOfEveryKindReopensForItsNextTurn() throws {
        for kind in [SubsessionLink.Kind.codexThread, .cursorTask, .declared] {
            var sessions: [String: SessionSnapshot] = [parent: SessionSnapshot()]
            try apply(folded("UserPromptSubmit", kind: kind, ["prompt": "task"]), to: &sessions)
            try apply(folded("Stop", kind: kind), to: &sessions)
            XCTAssertNil(sessions[parent]?.subagents[child], "\(kind)")
            XCTAssertTrue(sessions[parent]?.hasClosedSubagentId(child) == true, "\(kind)")

            try apply(folded("PostToolUse", kind: kind), to: &sessions)
            XCTAssertNil(sessions[parent]?.subagents[child], "\(kind): a hook trailing the Stop must not revive it")

            try apply(folded("UserPromptSubmit", kind: kind, ["prompt": "follow-up"]), to: &sessions)
            try apply(folded("PreToolUse", kind: kind, ["tool_name": "Edit"]), to: &sessions)
            XCTAssertEqual(sessions[parent]?.subagents[child]?.status, .running, "\(kind)")
            XCTAssertNotNil(sessions[parent]?.subagents[child]?.currentTool, "\(kind)")
        }
    }
}
