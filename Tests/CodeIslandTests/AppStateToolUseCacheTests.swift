import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateToolUseCacheTests: XCTestCase {

    // MARK: - Cache lifecycle

    func testPreToolUseCachesRecord() throws {
        let appState = AppState()
        let event = try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_1",
            toolInput: ["command": "ls"]
        )

        appState.handleEvent(event)

        let cached = try XCTUnwrap(appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "toolu_1")])
        XCTAssertEqual(cached.sessionId, "s1")
        XCTAssertEqual(cached.toolName, "Bash")
    }

    func testPostToolUseClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))
        XCTAssertNotNil(appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "toolu_1")])

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "toolu_1")])
    }

    func testPostToolUseFailureAlsoClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        appState.handleEvent(try makeHookEvent(name: "PostToolUseFailure", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "toolu_1")])
    }

    func testPruneRemovesExpiredRecords() throws {
        let appState = AppState()
        appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "ancient")] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date(timeIntervalSinceNow: -(AppState.pendingToolUseTTL + 60))
        )
        appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "fresh")] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date()
        )

        appState.prunePendingToolUses()

        XCTAssertNil(appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "ancient")])
        XCTAssertNotNil(appState.pendingToolUses[ToolUseKey(sessionId: "s1", toolUseId: "fresh")])
    }

    // MARK: - Duplicate PermissionRequest replay

    /// The replaced waiter gets no decision: a replay is no answer to the
    /// request it repeats.
    func testDuplicatePermissionRequestReplacesContinuationAndLeavesOldUndecided() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")
        let second = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")

        let firstTask = await startHookRequest { appState.handlePermissionRequest(first, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let secondTask = await startHookRequest { appState.handlePermissionRequest(second, continuation: $0) }

        // The old continuation is answered at once, deciding nothing; queue length stays 1.
        let firstResponse = try await awaitValue(of: firstTask)
        XCTAssertEqual(firstResponse, AppState.noDecisionAnswer)
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Second (replacement) continuation still waits for user decision.
        appState.approvePermission()
        let secondResponse = try await awaitValue(of: secondTask)
        XCTAssertEqual(try behavior(secondResponse), "allow")
    }

    /// Repro for #169: parallel tool calls that share a tool_use_id but operate
    /// on different inputs (e.g. "Read 4 files" at once) must not deny one
    /// another. Merging by id alone denied all but the last, which users saw as
    /// "denied by PermissionRequest hook" on tools they never rejected.
    func testParallelRequestsSharingIdButDifferentInputAreNotMerged() async throws {
        let appState = AppState()
        let readA = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Read",
            toolUseId: "shared_id", toolInput: ["file_path": "/a.txt"]
        )
        let readB = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Read",
            toolUseId: "shared_id", toolInput: ["file_path": "/b.txt"]
        )

        let taskA = await startHookRequest { appState.handlePermissionRequest(readA, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let taskB = await startHookRequest { appState.handlePermissionRequest(readB, continuation: $0) }

        XCTAssertEqual(appState.permissionQueue.count, 2,
            "Parallel requests with different inputs must not deny each other (#169)")
        await assertStillPending(taskA)

        // Both stay until the user decides each one.
        appState.approvePermission()
        let responseA = try await awaitValue(of: taskA)
        XCTAssertEqual(try behavior(responseA), "allow")
        appState.approvePermission()
        let responseB = try await awaitValue(of: taskB)
        XCTAssertEqual(try behavior(responseB), "allow")
    }

    // MARK: - Stale queue drain via PostToolUse

    func testPostToolUseDrainsQueuedPermissionForSameId() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_drain")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(pending, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Agent moved on — emits PostToolUse for the same tool_use_id.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_drain"
        ))

        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(response, AppState.noDecisionAnswer)
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPostToolUseDoesNotAffectUnrelatedQueueEntries() async throws {
        let appState = AppState()
        let kept = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "keep_me")
        let drained = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "drop_me")

        let keptTask = await startHookRequest { appState.handlePermissionRequest(kept, continuation: $0) }
        let drainedTask = await startHookRequest { appState.handlePermissionRequest(drained, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "drop_me"
        ))

        let drainedResponse = try await awaitValue(of: drainedTask)
        XCTAssertEqual(drainedResponse, AppState.noDecisionAnswer)
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "keep_me")

        appState.approvePermission()
        let keptResponse = try await awaitValue(of: keptTask)
        XCTAssertEqual(try behavior(keptResponse), "allow")
    }

    // MARK: - issue #216: orphan permissions (no tool_use_id) auto-dismiss on terminal approval

    /// Repro for #216: a PermissionRequest carrying NO tool_use_id can never be
    /// correlated by resolveToolUseIfCompleted, so approving in the terminal left
    /// the card up until the user closed it manually. After the fix, a follow-up
    /// step of the same agent takes the card down — answered with no decision,
    /// never allow: the island does not know what the user chose there.
    func testOrphanPermissionResolvedByFollowUpActivity() async throws {
        let appState = AppState()
        let orphan = try makeHookEvent(
            name: "PermissionRequest",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: nil,
            toolInput: ["command": "echo hi"]
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(orphan, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertNil(appState.permissionQueue.first?.toolUseId)

        // Agent moved on (user approved in terminal) — a follow-up PostToolUse
        // arrives for the same session with no correlatable tool_use_id.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: nil
        ))

        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(response, AppState.noDecisionAnswer)
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    /// Guard for #147 inside the #216 fix: an orphan-drain triggered by a follow-up
    /// activity event must NOT touch permission requests that carry a tool_use_id —
    /// those still wait for proper correlation so parallel tool calls don't deny
    /// each other.
    func testOrphanDrainDoesNotResolvePermissionWithToolUseId() async throws {
        let appState = AppState()
        let correlated = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_keep")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(correlated, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Unrelated follow-up activity (different/absent tool_use_id) for the same
        // session. The correlated request keeps waiting.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_other"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1,
            "Permission with a tool_use_id must not be drained by an unrelated follow-up (#147)")
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_keep")
        await assertStillPending(responseTask)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "allow")
    }

    // MARK: - issue #147 regression: parallel/plugin tool calls must not deny pending permissions

    /// Repro for #147: a Stop (or any non-keepWaiting activity event) arriving
    /// while a PermissionRequest is pending used to trigger a wasWaiting blanket
    /// drain that denied the queued request before the user could react.
    /// After the fix, only surgical (tool_use_id) drains may remove a queued
    /// permission — unrelated activity events leave the queue alone.
    func testStopEventDoesNotDenyPendingPermission() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_keep")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(pending, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions["s1"]?.status, .waitingApproval)

        // Activity event for the same session that carries no tool_use_id.
        // Pre-fix this would blanket-drain the pending permission via the
        // wasWaiting branch in handleEvent.
        appState.handleEvent(try makeHookEvent(
            name: "Stop",
            sessionId: "s1",
            toolName: nil,
            toolUseId: nil
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1, "Stop must not deny a pending PermissionRequest with a different/absent tool_use_id (#147)")
        await assertStillPending(responseTask)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "allow")
    }

    /// Repro for #147 with parallel tools: Notion / MCP plugin invokes two
    /// fetches at once. The first PostToolUse arrives (its PreToolUse was never
    /// cached, so `resolveToolUseIfCompleted` finds nothing to drain) while the
    /// second tool's PermissionRequest is still pending. Pre-fix, the blanket
    /// drain would deny the pending second request; the UI flashed a card and
    /// users saw "denied by PermissionRequest hook" before they could react.
    func testParallelPostToolUseDoesNotDenyUnrelatedPendingPermission() async throws {
        let appState = AppState()
        let pendingForToolB = try makePermissionEvent(
            sessionId: "s1",
            toolName: "mcp__notion__notion-fetch",
            toolUseId: "toolu_B"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(pendingForToolB, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Tool A finishes — PostToolUse arrives with a tool_use_id that was
        // never in the queue (and never cached, since we skipped its PreToolUse
        // for this scenario). resolveToolUseIfCompleted removes nothing.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "mcp__notion__notion-fetch",
            toolUseId: "toolu_A"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1,
            "Unrelated PostToolUse must not deny pending PermissionRequest for parallel tool (#147)")
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_B")
        await assertStillPending(responseTask)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "allow")
    }

    /// A background subagent shares its parent's session_id. Its PostToolUse /
    /// SubagentStop arriving while the main thread's AskUserQuestion is on screen
    /// used to blanket-drain the question, so Claude saw "Permission denied by hook".
    /// The main thread's own PostToolUse (answered in the terminal) still drains it.
    func testSubagentActivityDoesNotDenyMainThreadQuestion() async throws {
        let appState = AppState()
        let ask = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Fix it?", "options": [["label": "Yes"], ["label": "No"]]]]],
        ])
        let responseTask = await startHookRequest { appState.handleAskUserQuestion(ask, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.count, 1)

        for name in ["PostToolUse", "SubagentStop"] {
            appState.handleEvent(try makeRawHookEvent([
                "hook_event_name": name,
                "session_id": "s1",
                "agent_id": "bg-agent",
                "tool_name": "Bash",
                "tool_use_id": "toolu_bg_\(name)",
            ]))
        }
        XCTAssertEqual(appState.questionQueue.count, 1, "subagent activity must not drain the parent's question")
        await assertStillPending(responseTask)

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "AskUserQuestion", toolUseId: "toolu_ask"))
        XCTAssertTrue(appState.questionQueue.isEmpty, "main-thread activity still means the question was answered elsewhere")
        _ = try await awaitValue(of: responseTask)
    }

    /// The other per-session drains had the same blind spot: a subagent's new
    /// permission request, its own question, or its hook socket dropping each
    /// denied the main thread's pending question.
    func testSubagentRequestsAndDisconnectsDoNotDenyMainThreadQuestion() async throws {
        let appState = AppState()
        let mainAsk = try makeAskEvent(agentId: nil)
        let mainResponse = await startHookRequest { appState.handleAskUserQuestion(mainAsk, continuation: $0) }

        let subBash = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "agent_id": "bg-agent",
            "tool_name": "Bash",
            "tool_use_id": "toolu_sub_bash",
        ])
        let subPermission = await startHookRequest { appState.handlePermissionRequest(subBash, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.map(\.event.agentId), [nil], "a subagent's permission request must not deny the parent's question")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let subAsk = try makeAskEvent(agentId: "bg-agent")
        let subQuestion = await startHookRequest { appState.handleAskUserQuestion(subAsk, continuation: $0) }

        // A new question from the subagent still supersedes that subagent's own
        // permission request, but leaves the parent's question alone.
        _ = try await awaitValue(of: subPermission)
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertEqual(appState.questionQueue.map(\.event.agentId), [nil, "bg-agent"])
        await assertStillPending(mainResponse)

        // The subagent's hook socket drops: only its own request goes.
        appState.handlePeerDisconnect(sessionId: "s1", agentId: "bg-agent")
        _ = try await awaitValue(of: subQuestion)
        XCTAssertEqual(appState.questionQueue.map(\.event.agentId), [nil])
        XCTAssertEqual(appState.sessions["s1"]?.status, .waitingQuestion)
        await assertStillPending(mainResponse)

        appState.handlePeerDisconnect(sessionId: "s1")
        _ = try await awaitValue(of: mainResponse)
        XCTAssertTrue(appState.questionQueue.isEmpty)
    }

    private func makeAskEvent(agentId: String?) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Fix it?", "options": [["label": "Yes"], ["label": "No"]]]]],
        ]
        if let agentId { payload["agent_id"] = agentId }
        return try makeRawHookEvent(payload)
    }

    func testTraePostToolUseKeepsQueuedPermissionUntilUserResponds() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_trae",
            source: "traecli"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(pending, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_trae",
            source: "traecli"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1)
        await assertStillPending(responseTask)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "allow")
    }

    // MARK: - Cline task lifecycle

    func testClineTaskCompleteEndsSessionImmediately() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "TaskResume",
            sessionId: "cline-1",
            toolName: nil,
            toolUseId: nil,
            source: "cline"
        ))
        XCTAssertEqual(appState.sessions["cline-1"]?.status, .processing)
        XCTAssertEqual(appState.activeSessionCount, 1)

        appState.handleEvent(try makeHookEvent(
            name: "TaskComplete",
            sessionId: "cline-1",
            toolName: nil,
            toolUseId: nil,
            source: "cline"
        ))

        XCTAssertEqual(appState.sessions["cline-1"]?.status, .idle)
        XCTAssertEqual(appState.sessions["cline-1"]?.taskRoundEnded, true)
        XCTAssertEqual(appState.activeSessionCount, 0)
    }

    func testClineDropsStaleToolEventsAfterTaskComplete() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "TaskResume",
            sessionId: "cline-1",
            toolName: nil,
            toolUseId: nil,
            source: "cline"
        ))
        appState.handleEvent(try makeHookEvent(
            name: "PreToolUse",
            sessionId: "cline-1",
            toolName: "execute_command",
            toolUseId: "toolu_cline",
            source: "cline"
        ))
        appState.handleEvent(try makeHookEvent(
            name: "TaskComplete",
            sessionId: "cline-1",
            toolName: nil,
            toolUseId: nil,
            source: "cline"
        ))

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "cline-1",
            toolName: "execute_command",
            toolUseId: "toolu_cline",
            source: "cline"
        ))

        XCTAssertEqual(appState.sessions["cline-1"]?.status, .idle)
        XCTAssertNil(appState.sessions["cline-1"]?.currentTool)
        XCTAssertEqual(appState.activeSessionCount, 0)
    }

    // MARK: - Backfill from cache

    func testEnrichBackfillsMissingToolNameFromCache() async throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_enrich",
            toolInput: ["command": "ls"]
        ))

        // PermissionRequest payload omits tool_name (simulates a thin third-party re-emit).
        let thin = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_use_id": "toolu_enrich"
        ])

        // Check once the handler has actually run: a bare Task was never
        // scheduled before this synchronous test read the session.
        let response = await startHookRequest { appState.handlePermissionRequest(thin, continuation: $0) }
        let session = appState.sessions["s1"]
        XCTAssertEqual(session?.currentTool, "Bash")

        appState.handlePeerDisconnect(sessionId: "s1")
        _ = try await awaitValue(of: response)
    }

    // MARK: - Helpers

    private func makeHookEvent(
        name: String,
        sessionId: String,
        toolName: String?,
        toolUseId: String?,
        toolInput: [String: Any]? = nil,
        source: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId
        ]
        if let toolName { payload["tool_name"] = toolName }
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        if let toolInput { payload["tool_input"] = toolInput }
        if let source { payload["_source"] = source }
        return try makeRawHookEvent(payload)
    }

    private func makePermissionEvent(sessionId: String, toolName: String, toolUseId: String, source: String? = nil) throws -> HookEvent {
        try makeHookEvent(
            name: "PermissionRequest",
            sessionId: sessionId,
            toolName: toolName,
            toolUseId: toolUseId,
            toolInput: ["command": "echo hi"],
            source: source
        )
    }

    private func makeRawHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "AppStateToolUseCacheTests", code: 1)
        }
        return event
    }

    private func behavior(_ data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecific["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
