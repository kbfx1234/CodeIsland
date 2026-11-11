import XCTest
@testable import CodeIslandCore

/// A child session that names its parent (#378): pi-subagents runs every
/// background child as a pi session of its own, and each one used to ring the
/// completion sound like a top-level session. Payloads below are the pi
/// extension's (codeisland-pi.ts v5).
final class DeclaredSubsessionTests: XCTestCase {
    private let parentId = "pi-01a15910-e6c0-75af-93e2-e9c1825affc1"
    private let childId = "pi-01a15911-8771-7000-8000-000000000001"
    private let siblingId = "pi-01a15911-877f-7000-8000-000000000002"

    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    @discardableResult
    private func apply(
        _ payload: [String: Any],
        to sessions: inout [String: SessionSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [SideEffect] {
        reduceEvent(sessions: &sessions, event: try hookEvent(payload, file: file, line: line), maxHistory: 20)
    }

    private func parentPayload(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        [
            "hook_event_name": event,
            "session_id": parentId,
            "_source": "pi",
            "_ppid": 90702,
            "cwd": "/repo",
        ].merging(extra) { _, new in new }
    }

    private func childPayload(_ event: String, child: String? = nil, _ extra: [String: Any] = [:]) -> [String: Any] {
        [
            "hook_event_name": event,
            "session_id": child ?? childId,
            "_source": "pi",
            "_ppid": 91170,
            "cwd": "/repo",
            DeclaredSubsession.parentKey: parentId,
            "agent_type": "worker",
        ].merging(extra) { _, new in new }
    }

    /// What HookServer hands the reducer in merge mode.
    private func merged(_ payload: [String: Any], into card: String? = nil) -> [String: Any] {
        var raw = payload
        guard let link = DeclaredSubsession.link(in: raw) else {
            XCTFail("a declared child: \(payload)")
            return raw
        }
        XCTAssertTrue(SubsessionRouter.fold(&raw, link: link, into: card ?? parentId))
        return raw
    }

    /// Fold a payload the way Merge does, as the declared child it names.
    @discardableResult
    private func fold(_ raw: inout [String: Any], into card: String) -> Bool {
        guard let link = DeclaredSubsession.link(in: raw) else { return false }
        return SubsessionRouter.fold(&raw, link: link, into: card)
    }

    private func sounds(_ effects: [SideEffect]) -> [String] {
        effects.compactMap {
            if case .playSound(let name) = $0 { return name }
            return nil
        }
    }

    private func completions(_ effects: [SideEffect]) -> [String] {
        effects.compactMap {
            if case .enqueueCompletion(let id) = $0 { return id }
            return nil
        }
    }

    // MARK: - The declaration

    func testParentIsReadInTheFormOfSessionId() {
        XCTAssertEqual(DeclaredSubsession.parentSessionId(in: [
            "session_id": childId,
            "_parent_session_id": " \(parentId) ",
        ]), parentId)
        XCTAssertNil(DeclaredSubsession.parentSessionId(in: ["session_id": childId]))
        XCTAssertNil(DeclaredSubsession.parentSessionId(in: ["session_id": childId, "_parent_session_id": "  "]))
        XCTAssertNil(
            DeclaredSubsession.parentSessionId(in: ["session_id": childId, "_parent_session_id": childId]),
            "a session is not its own parent"
        )
        // Filed like `session_id`, so it names the card the parent's events land on.
        XCTAssertEqual(DeclaredSubsession.parentSessionId(in: [
            "session_id": childId,
            "_parent_session_id": parentId,
            "_remote_host_id": "devbox",
        ]), "remote:devbox:\(parentId)")
        XCTAssertEqual(DeclaredSubsession.parentSessionId(in: [
            "session_id": "child-thread",
            "_parent_session_id": "parent-thread",
            "_source": "codex",
            "_term_bundle": "com.openai.codex",
        ]), "codexapp:parent-thread")
    }

    func testCardSessionIdMatchesHookEventFiling() throws {
        let remote = try hookEvent(["hook_event_name": "Stop", "session_id": "s", "_remote_host_id": "h"])
        XCTAssertEqual(remote.sessionId, "remote:h:s")
        let desktop = try hookEvent([
            "hook_event_name": "Stop", "session_id": "t", "_source": "codex", "_term_bundle": "com.openai.codex",
        ])
        XCTAssertEqual(desktop.sessionId, "codexapp:t")
        let prefixed = try hookEvent([
            "hook_event_name": "Stop", "session_id": "codexapp:t", "_source": "codex", "_term_bundle": "com.openai.codex",
        ])
        XCTAssertEqual(prefixed.sessionId, "codexapp:t")
        let blankHost = try hookEvent(["hook_event_name": "Stop", "session_id": "s", "_remote_host_id": " "])
        XCTAssertEqual(blankHost.sessionId, "s")
    }

    func testMergeRewritesOntoTheParentAndDropsTheDeclaration() {
        var raw = childPayload("PreToolUse", ["tool_name": "Bash"])
        XCTAssertTrue(fold(&raw, into: parentId))
        XCTAssertEqual(raw["session_id"] as? String, parentId)
        XCTAssertEqual(raw["agent_id"] as? String, childId)
        XCTAssertEqual(raw["agent_type"] as? String, "worker")
        XCTAssertEqual(raw[SubsessionRouter.foldedKey] as? String, SubsessionLink.Kind.declared.rawValue)
        XCTAssertNil(raw[DeclaredSubsession.parentKey], "it described the old session_id")

        var unnamed: [String: Any] = ["session_id": childId, "_parent_session_id": parentId]
        fold(&unnamed, into: parentId)
        XCTAssertEqual(unnamed["agent_type"] as? String, SubsessionLink.Kind.declared.defaultAgentType)
    }

    func testMergeOnlyLandsOnACardThePayloadCanAddress() {
        var remote: [String: Any] = ["session_id": childId, "_parent_session_id": parentId, "_remote_host_id": "devbox"]
        XCTAssertEqual(DeclaredSubsession.link(in: remote)?.childCardId, "remote:devbox:\(childId)")
        XCTAssertTrue(fold(&remote, into: "remote:devbox:\(parentId)"))
        XCTAssertEqual(remote["session_id"] as? String, parentId, "HookEvent re-adds the host prefix")
        XCTAssertEqual(remote["agent_id"] as? String, "remote:devbox:\(childId)", "a declared row goes by the child's card id")

        var strayRemote: [String: Any] = ["session_id": childId, "_parent_session_id": parentId, "_remote_host_id": "devbox"]
        let before = strayRemote.count
        XCTAssertFalse(fold(&strayRemote, into: parentId))
        XCTAssertEqual(strayRemote.count, before)
        XCTAssertEqual(strayRemote["session_id"] as? String, childId, "left untouched")

        var desktop: [String: Any] = [
            "session_id": "child-thread", "_parent_session_id": "parent-thread",
            "_source": "codex", "_term_bundle": "com.openai.codex",
        ]
        XCTAssertFalse(fold(&desktop, into: "parent-thread"))
        XCTAssertTrue(fold(&desktop, into: "codexapp:parent-thread"))

        // TRAE stamps every hook with the running agent's id, so `agent_id`
        // cannot mark a folded child there.
        var trae: [String: Any] = ["session_id": childId, "_parent_session_id": parentId, "_source": "trae"]
        XCTAssertFalse(fold(&trae, into: parentId))
    }

    // MARK: - Separate cards: children stay quiet

    func testChildOnItsOwnCardNeverRingsOrCompletes() throws {
        var sessions: [String: SessionSnapshot] = [:]

        let start = try apply(childPayload("SessionStart", ["session_title": "worker: sleep 4"]), to: &sessions)
        let prompt = try apply(childPayload("UserPromptSubmit", ["prompt": "Task: sleep 4"]), to: &sessions)
        try apply(childPayload("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "sleep 4"]]), to: &sessions)
        try apply(childPayload("PostToolUse"), to: &sessions)
        let stop = try apply(childPayload("Stop", ["last_assistant_message": "done"]), to: &sessions)

        XCTAssertEqual(sounds(start + prompt + stop), [], "a child's start, prompt and turn end are not the user's")
        XCTAssertEqual(completions(stop), [], "no completion card or push for a child's turn")

        let child = try XCTUnwrap(sessions[childId])
        XCTAssertEqual(child.parentSessionId, parentId)
        XCTAssertEqual(child.status, .idle, "its card still settles")
        XCTAssertEqual(child.lastAssistantMessage, "done")
        XCTAssertEqual(child.sessionTitle, "worker: sleep 4")
        XCTAssertEqual(child.toolHistory.count, 1)
    }

    func testChildTurnFailureStaysSilentToo() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try apply(childPayload("SessionStart"), to: &sessions)
        let failed = try apply(childPayload("StopFailure", ["error": "rate_limit"]), to: &sessions)
        XCTAssertEqual(sounds(failed), [])
        XCTAssertEqual(completions(failed), [])
    }

    func testOnlyTheParentChimesWhenOneParentFansOutToTwoChildren() throws {
        var sessions: [String: SessionSnapshot] = [:]
        var effects: [SideEffect] = []

        effects += try apply(parentPayload("SessionStart"), to: &sessions)
        effects += try apply(parentPayload("UserPromptSubmit", ["prompt": "fan out to 2 subagents"]), to: &sessions)
        effects += try apply(parentPayload("PreToolUse", ["tool_name": "Subagent"]), to: &sessions)
        for child in [childId, siblingId] {
            effects += try apply(childPayload("SessionStart", child: child), to: &sessions)
            effects += try apply(childPayload("UserPromptSubmit", child: child, ["prompt": "Task: sleep 4"]), to: &sessions)
            effects += try apply(childPayload("Stop", child: child), to: &sessions)
            effects += try apply(childPayload("SessionEnd", child: child), to: &sessions)
        }
        effects += try apply(parentPayload("PostToolUse"), to: &sessions)
        effects += try apply(parentPayload("Stop", ["last_assistant_message": "all done"]), to: &sessions)

        XCTAssertEqual(sounds(effects).filter { $0 == "Stop" }.count, 1, "one turn the user started, one chime")
        XCTAssertEqual(sounds(effects).filter { $0 == "SessionStart" }.count, 1)
        XCTAssertEqual(completions(effects), [parentId])
        XCTAssertNil(sessions[parentId]?.parentSessionId)
    }

    func testDeclarationSurvivesTheSessionStartRebuild() throws {
        var sessions: [String: SessionSnapshot] = [:]
        // A hook that reaches the card before its SessionStart already links it…
        try apply(childPayload("UserPromptSubmit", ["prompt": "Task"]), to: &sessions)
        XCTAssertEqual(sessions[childId]?.parentSessionId, parentId)
        // …and the SessionStart that rebuilds the snapshot keeps the link.
        let start = try apply(childPayload("SessionStart"), to: &sessions)
        XCTAssertEqual(sessions[childId]?.parentSessionId, parentId)
        XCTAssertEqual(sounds(start), [])
    }

    // MARK: - Merge: folded into the parent's card

    func testFoldedChildIsASubagentOfTheParentCard() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try apply(parentPayload("UserPromptSubmit", ["prompt": "fan out"]), to: &sessions)

        var effects = try apply(merged(childPayload("SessionStart")), to: &sessions)
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.agentType, "worker")
        XCTAssertEqual(sessions[parentId]?.status, .running)
        XCTAssertEqual(sessions[parentId]?.currentTool, "Agent")
        XCTAssertNil(sessions[childId], "no card of its own")

        effects += try apply(merged(childPayload("UserPromptSubmit", ["prompt": "Task: sleep 4"])), to: &sessions)
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .processing)
        XCTAssertEqual(sessions[parentId]?.lastUserPrompt, "fan out", "the child's prompt is not the parent's")

        effects += try apply(merged(childPayload("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "sleep 4"]])), to: &sessions)
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.currentTool, "Bash")
        effects += try apply(merged(childPayload("PostToolUse")), to: &sessions)
        XCTAssertEqual(sessions[parentId]?.toolHistory.last?.agentType, "worker")

        let stop = try apply(merged(childPayload("Stop", ["last_assistant_message": "child done"])), to: &sessions)
        effects += stop
        XCTAssertNil(sessions[parentId]?.subagents[childId])
        XCTAssertNotEqual(sessions[parentId]?.status, .idle, "a child's Stop is not the parent's")
        XCTAssertNotEqual(sessions[parentId]?.lastAssistantMessage, "child done")
        XCTAssertEqual(sounds(effects), [])
        XCTAssertEqual(completions(effects), [])

        let parentStop = try apply(parentPayload("Stop", ["last_assistant_message": "all done"]), to: &sessions)
        XCTAssertEqual(sounds(parentStop), ["Stop"])
        XCTAssertEqual(completions(parentStop), [parentId])
        XCTAssertEqual(sessions[parentId]?.status, .idle)
    }

    func testParentTurnEndWhileFoldedChildrenWorkKeepsTheCardRunning() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try apply(parentPayload("UserPromptSubmit", ["prompt": "launch in background"]), to: &sessions)
        try apply(merged(childPayload("SessionStart")), to: &sessions)
        try apply(merged(childPayload("UserPromptSubmit", ["prompt": "Task"])), to: &sessions)

        let parentStop = try apply(parentPayload("Stop"), to: &sessions)
        XCTAssertEqual(completions(parentStop), [], "children still working")
        XCTAssertEqual(sessions[parentId]?.status, .running)
    }

    func testFoldedChildReopensForItsNextTurnAndClosesAtSessionEnd() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try apply(parentPayload("UserPromptSubmit", ["prompt": "fan out"]), to: &sessions)
        try apply(merged(childPayload("SessionStart")), to: &sessions)
        try apply(merged(childPayload("UserPromptSubmit", ["prompt": "Task"])), to: &sessions)
        try apply(merged(childPayload("Stop")), to: &sessions)
        XCTAssertTrue(sessions[parentId]?.hasClosedSubagentId(childId) == true)

        // A tool hook trailing the Stop must not bring a finished turn back.
        try apply(merged(childPayload("PostToolUse")), to: &sessions)
        XCTAssertNil(sessions[parentId]?.subagents[childId])

        // pi-subagents can prompt the same child again (acceptance retry, steering).
        try apply(merged(childPayload("UserPromptSubmit", ["prompt": "fix the acceptance check"])), to: &sessions)
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .processing)
        try apply(merged(childPayload("PreToolUse", ["tool_name": "Edit"])), to: &sessions)
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.currentTool, "Edit")

        try apply(merged(childPayload("Stop")), to: &sessions)
        try apply(merged(childPayload("SessionEnd")), to: &sessions)
        XCTAssertNil(sessions[parentId]?.subagents[childId])
        XCTAssertNotNil(sessions[parentId], "the child's SessionEnd never removes the parent card")
    }

    func testFoldedChildCompactionLeavesTheParentAlone() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try apply(parentPayload("UserPromptSubmit", ["prompt": "fan out"]), to: &sessions)
        try apply(merged(childPayload("SessionStart")), to: &sessions)
        sessions[parentId]?.status = .waitingApproval
        sessions[parentId]?.toolDescription = "rm -rf build"

        try apply(merged(childPayload("PreCompact")), to: &sessions)
        try apply(merged(childPayload("PostCompact")), to: &sessions)

        XCTAssertEqual(sessions[parentId]?.status, .waitingApproval)
        XCTAssertEqual(sessions[parentId]?.toolDescription, "rm -rf build")
        XCTAssertNotNil(sessions[parentId]?.subagents[childId])
    }
}
