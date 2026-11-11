import XCTest
@testable import CodeIslandCore

/// Agent checklist progress: Claude TaskCreate/TaskUpdate, TodoWrite, Codex
/// update_plan — via hooks (reducer), transcript rows (tailer) and backfill.
final class AgentTaskListTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Claude Task tools via hooks

    func testClaudeTaskToolsViaHooksBuildProgress() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, preCreate("toolu_c1", "Write parser", activeForm: "Writing parser"))
        reduce(&sessions, postCreate("toolu_c1", "Write parser", id: "1"))
        reduce(&sessions, preCreate("toolu_c2", "Add tests", activeForm: "Adding tests"))
        reduce(&sessions, postCreate("toolu_c2", "Add tests", id: "2"))
        reduce(&sessions, preUpdate("toolu_u1", taskId: "1", status: "in_progress"))
        reduce(&sessions, postUpdate("toolu_u1", taskId: "1", from: "pending", to: "in_progress"))

        var tasks = sessions["s1"]!.agentTasks
        XCTAssertEqual(tasks.items.map(\.taskId), ["1", "2"])
        XCTAssertEqual(tasks.items.map(\.title), ["Write parser", "Add tests"])
        XCTAssertEqual(tasks.current?.progressLabel, "Writing parser")
        XCTAssertEqual(tasks.completedCount, 0)

        reduce(&sessions, preUpdate("toolu_u2", taskId: "1", status: "completed"))
        reduce(&sessions, preUpdate("toolu_u3", taskId: "2", status: "in_progress"))
        tasks = sessions["s1"]!.agentTasks
        XCTAssertEqual(tasks.completedCount, 1)
        XCTAssertEqual(tasks.current?.progressLabel, "Adding tests")
        XCTAssertFalse(tasks.isAllCompleted)
    }

    func testUpdateBeforeCreateResultIsParkedUntilTheIdArrives() {
        // Claude's PostToolUse hooks run async: the next TaskUpdate's
        // PreToolUse can land before the TaskCreate result names the id.
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, preCreate("toolu_c1", "Write parser"))
        reduce(&sessions, preUpdate("toolu_u1", taskId: "1", status: "in_progress"))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.status), [.pending])

        reduce(&sessions, postCreate("toolu_c1", "Write parser", id: "1"))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.status), [.inProgress])
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.taskId), ["1"])
    }

    func testUpdateArrivingBeforeAnyCreateLandsOnceTheRowExists() {
        var list = AgentTaskList()
        list.apply([
            .update(opId: "u1", taskId: "3", change: AgentTaskChange(status: .completed), expectedFrom: nil),
            .created(opId: "c3", taskId: "3", title: "Ship it", activeForm: nil),
        ], now: t0)
        XCTAssertEqual(list.items.map(\.title), ["Ship it"])
        XCTAssertEqual(list.items.map(\.status), [.completed])
    }

    func testLateAsyncResultCannotRollStatusBack() {
        var list = AgentTaskList()
        list.apply([
            .created(opId: "c1", taskId: "1", title: "A", activeForm: nil),
            .update(opId: "u2", taskId: "1", change: AgentTaskChange(status: .completed), expectedFrom: nil),
            // Result of an earlier update whose call we never saw.
            .update(opId: "u1", taskId: "1", change: AgentTaskChange(status: .inProgress), expectedFrom: .pending),
        ], now: t0)
        XCTAssertEqual(list.items.map(\.status), [.completed])
    }

    func testDuplicateHookEventsApplyOnce() {
        var sessions: [String: SessionSnapshot] = [:]
        for _ in 0..<2 {
            reduce(&sessions, preCreate("toolu_c1", "Write parser"))
            reduce(&sessions, postCreate("toolu_c1", "Write parser", id: "1"))
            reduce(&sessions, preUpdate("toolu_u1", taskId: "1", status: "completed"))
        }
        let tasks = sessions["s1"]!.agentTasks
        XCTAssertEqual(tasks.items.count, 1)
        XCTAssertEqual(tasks.completedCount, 1)
    }

    func testDeletedTaskLeavesTheList() {
        var list = AgentTaskList()
        list.apply([
            .created(opId: "c1", taskId: "1", title: "Keep", activeForm: nil),
            .created(opId: "c2", taskId: "2", title: "Drop", activeForm: nil),
            .update(opId: "u1", taskId: "2", change: AgentTaskChange(isDeletion: true), expectedFrom: nil),
        ], now: t0)
        XCTAssertEqual(list.items.map(\.title), ["Keep"])

        // A deletion that overtakes the create result is parked, then applied.
        list.apply([
            .create(opId: "c3", title: "Gone", activeForm: nil),
            .update(opId: "u3", taskId: "3", change: AgentTaskChange(isDeletion: true), expectedFrom: nil),
            .created(opId: "c3", taskId: "3", title: "Gone", activeForm: nil),
        ], now: t0)
        XCTAssertEqual(list.items.map(\.title), ["Keep"])
    }

    func testDeletedStatusFromHookRemovesRow() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, preCreate("toolu_c1", "A"))
        reduce(&sessions, postCreate("toolu_c1", "A", id: "1"))
        reduce(&sessions, preCreate("toolu_c2", "B"))
        reduce(&sessions, postCreate("toolu_c2", "B", id: "2"))
        reduce(&sessions, preUpdate("toolu_u1", taskId: "1", status: "deleted"))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.title), ["B"])
    }

    func testFailedUpdateIsUndone() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, preCreate("toolu_c1", "A"))
        reduce(&sessions, postCreate("toolu_c1", "A", id: "1"))
        reduce(&sessions, preUpdate("toolu_u1", taskId: "1", status: "in_progress"))
        reduce(&sessions, preUpdate("toolu_u2", taskId: "1", status: "completed"))
        // A TaskCompleted hook blocked the completion.
        reduce(&sessions, [
            "hook_event_name": "PostToolUse",
            "tool_name": "TaskUpdate",
            "tool_use_id": "toolu_u2",
            "tool_input": ["taskId": "1", "status": "completed"],
            "tool_response": ["success": false, "taskId": "1", "updatedFields": [String](), "error": "blocked"],
        ])
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.status), [.inProgress])
    }

    func testFailedCreateDropsTheDraft() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, preCreate("toolu_c1", "A"))
        reduce(&sessions, [
            "hook_event_name": "PostToolUseFailure",
            "tool_name": "TaskCreate",
            "tool_use_id": "toolu_c1",
            "tool_input": ["subject": "A"],
        ])
        XCTAssertTrue(sessions["s1"]!.agentTasks.isEmpty)
    }

    // MARK: - Snapshot lists

    func testTodoWriteSnapshotReplacesTheList() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, todoWrite("toolu_w1", [
            ("Read code", "completed"), ("Fix bug", "in_progress"), ("Run tests", "pending"),
        ]))
        var tasks = sessions["s1"]!.agentTasks
        XCTAssertEqual(tasks.items.map(\.title), ["Read code", "Fix bug", "Run tests"])
        XCTAssertEqual(tasks.current?.progressLabel, "Fix bug…ing")
        XCTAssertEqual(tasks.completedCount, 1)

        reduce(&sessions, todoWrite("toolu_w2", [
            ("Read code", "completed"), ("Fix bug", "completed"), ("Run tests", "in_progress"),
        ]))
        // PostToolUse repeats the same call — applied once.
        var post = todoWrite("toolu_w2", [("Read code", "completed")])
        post["hook_event_name"] = "PostToolUse"
        reduce(&sessions, post)
        tasks = sessions["s1"]!.agentTasks
        XCTAssertEqual(tasks.items.count, 3)
        XCTAssertEqual(tasks.completedCount, 2)

        reduce(&sessions, todoWrite("toolu_w3", []))
        XCTAssertTrue(sessions["s1"]!.agentTasks.isEmpty)
    }

    func testCursorTodoWriteMergeUpdatesRowsByIdInsteadOfReplacingTheList() {
        func todoWrite(_ opId: String, merge: Bool, _ todos: [[String: Any]]) -> [String: Any] {
            [
                "hook_event_name": "preToolUse",
                "tool_name": "todo_write",
                "tool_use_id": opId,
                "tool_input": ["merge": merge, "todos": todos],
            ]
        }
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, todoWrite("w1", merge: false, [
            ["id": "1", "content": "Scan the repo", "status": "in_progress"],
            ["id": "2", "content": "Fix the bug", "status": "pending"],
            ["id": "3", "content": "Run tests", "status": "pending"],
        ]))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.taskId), ["1", "2", "3"])

        // Cursor's partial update: only ids and statuses.
        reduce(&sessions, todoWrite("w2", merge: true, [
            ["id": "1", "status": "completed"],
            ["id": "2", "status": "in_progress"],
        ]))
        var tasks = sessions["s1"]!.agentTasks
        XCTAssertEqual(tasks.items.map(\.title), ["Scan the repo", "Fix the bug", "Run tests"])
        XCTAssertEqual(tasks.items.map(\.status), [.completed, .inProgress, .pending])

        // A merge can rename a row, add one, and cancel one.
        reduce(&sessions, todoWrite("w3", merge: true, [
            ["id": "2", "content": "Fix the parser bug"],
            ["id": "4", "content": "Update docs", "status": "pending"],
            ["id": "3", "status": "cancelled"],
            ["id": "99", "status": "completed"],
        ]))
        tasks = sessions["s1"]!.agentTasks
        XCTAssertEqual(tasks.items.map(\.title), ["Scan the repo", "Fix the parser bug", "Update docs"])
        XCTAssertEqual(tasks.items.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(Set(tasks.items.map(\.id)).count, 3, "row identities stay unique")

        // merge:false is still a whole-list replacement.
        reduce(&sessions, todoWrite("w4", merge: false, [["id": "9", "content": "Fresh", "status": "pending"]]))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.title), ["Fresh"])
    }

    func testMergeOfIdOnlyRowsIntoAnEmptyListShowsNothing() {
        var list = AgentTaskList()
        list.apply(.merge(opId: "w1", rows: [
            AgentTaskRowPatch(rowId: "1", change: AgentTaskChange(status: .completed)),
        ]), now: t0)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(
            AgentTaskParsing.rowPatches(from: [["id": 7, "status": "done"], ["status": "pending"], "junk"]),
            [AgentTaskRowPatch(rowId: "7", change: AgentTaskChange(status: .completed))]
        )
    }

    func testCodexUpdatePlanFromRolloutLine() {
        let line = codexPlanLine(callId: "call_p1", steps: [
            ("Inspect intro", "completed"), ("Rewrite framing", "in_progress"), ("Compile", "pending"),
        ])
        // Function calls normally skip the JSON parser; update_plan must not.
        XCTAssertEqual(JSONLTailer.quickTypeProbe(lineBytes: Data(line.utf8)), .codexResponseItem)

        let result = JSONLTailer.scanLines(Data((line + "\n").utf8))
        var list = AgentTaskList()
        list.apply(result.delta.taskEvents, now: t0)
        XCTAssertEqual(list.items.map(\.title), ["Inspect intro", "Rewrite framing", "Compile"])
        XCTAssertEqual(list.items.map(\.status), [.completed, .inProgress, .pending])

        // The rest of the function-call traffic stays on the no-parse path.
        let exec = #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls\"}","call_id":"call_x"}}"#
        XCTAssertEqual(JSONLTailer.quickTypeProbe(lineBytes: Data(exec.utf8)), .irrelevant)
        let output = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_p1","output":"Plan updated"}}"#
        XCTAssertTrue(JSONLTailer.scanLines(Data((output + "\n").utf8)).delta.taskEvents.isEmpty)
    }

    func testCodexTurnStartIsANewTurn() {
        let started = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#
        let result = JSONLTailer.scanLines(Data((started + "\n").utf8))
        XCTAssertEqual(result.delta.taskEvents, [.newTurn])
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t2"}}"#
        XCTAssertEqual(JSONLTailer.scanLines(Data((complete + "\n").utf8)).delta.taskEvents, [.turnEnded])
    }

    // MARK: - Turn boundaries

    func testNewTurnClearsOnlyAFinishedList() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, todoWrite("toolu_w1", [("A", "completed"), ("B", "in_progress")]))
        reduce(&sessions, ["hook_event_name": "UserPromptSubmit", "prompt": "keep going"])
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.count, 2, "an unfinished plan survives a new prompt")

        reduce(&sessions, todoWrite("toolu_w2", [("A", "completed"), ("B", "completed")]))
        XCTAssertTrue(sessions["s1"]!.agentTasks.isAllCompleted)
        reduce(&sessions, ["hook_event_name": "UserPromptSubmit", "prompt": "next thing"])
        XCTAssertTrue(sessions["s1"]!.agentTasks.isEmpty)
    }

    // MARK: - Abandoned snapshot plans

    private func unfinishedPlan(_ opId: String) -> AgentTaskEvent {
        .replace(opId: opId, items: [
            AgentTaskDraft(title: "Read", status: .completed),
            AgentTaskDraft(title: "Patch", status: .inProgress),
            AgentTaskDraft(title: "Test", status: .pending),
        ])
    }

    func testSnapshotPlanRetiresAfterAWholeTurnWithoutUpdates() {
        var list = AgentTaskList()
        list.apply([.newTurn, unfinishedPlan("p1")], now: t0)
        list.apply(.turnEnded, now: t0.addingTimeInterval(60))

        // Next turn: the plan is still the agent's until a turn ignores it.
        list.apply(.newTurn, now: t0.addingTimeInterval(100))
        XCTAssertEqual(list.items.count, 3)
        list.apply(.turnEnded, now: t0.addingTimeInterval(160))

        list.apply(.newTurn, now: t0.addingTimeInterval(200))
        XCTAssertTrue(list.isEmpty, "a plan a whole turn went by without is abandoned")
    }

    func testAPlanUpdatedDuringTheTurnSurvives() {
        var list = AgentTaskList()
        list.apply([.newTurn, unfinishedPlan("p1")], now: t0)
        list.apply(.turnEnded, now: t0.addingTimeInterval(60))
        list.apply(.newTurn, now: t0.addingTimeInterval(100))
        list.apply(unfinishedPlan("p2"), now: t0.addingTimeInterval(120))
        list.apply(.turnEnded, now: t0.addingTimeInterval(160))
        list.apply(.newTurn, now: t0.addingTimeInterval(200))
        XCTAssertEqual(list.items.count, 3)

        // An unrelated failing tool is not an update of the plan.
        list.apply(.opFailed(opId: "toolu_bash"), now: t0.addingTimeInterval(210))
        list.apply(.turnEnded, now: t0.addingTimeInterval(260))
        list.apply(.newTurn, now: t0.addingTimeInterval(300))
        XCTAssertTrue(list.isEmpty)
    }

    func testBoundariesFromBothChannelsDoNotRetireAPlanInUse() {
        // A queued Codex prompt runs right after the previous turn: the hooks
        // (Stop, UserPromptSubmit) and the rollout (task_complete,
        // task_started, user_message) report the same two boundaries, the
        // rollout's late.
        var list = AgentTaskList()
        list.apply([.newTurn, unfinishedPlan("p1")], now: t0)
        let end = t0.addingTimeInterval(60)
        list.apply(.turnEnded, now: end)                               // hook Stop
        list.apply(.newTurn, now: end.addingTimeInterval(0.1))         // hook UserPromptSubmit
        list.apply(.turnEnded, now: end.addingTimeInterval(0.2))       // rollout task_complete (previous turn)
        list.apply(.newTurn, now: end.addingTimeInterval(0.3))         // rollout task_started
        list.apply(.newTurn, now: end.addingTimeInterval(0.3))         // rollout user_message
        XCTAssertEqual(list.items.count, 3)
        list.apply(.newTurn, now: end.addingTimeInterval(1))
        XCTAssertEqual(list.items.count, 3, "repeated starts of one turn change nothing")
    }

    func testTaskCreateListsAreNotRetiredForAnUntouchedTurn() {
        // Claude's tasks live on in the CLI's own task store.
        var list = AgentTaskList()
        list.apply([.newTurn, .created(opId: "c1", taskId: "1", title: "A", activeForm: nil)], now: t0)
        for turn in 1...3 {
            list.apply(.turnEnded, now: t0.addingTimeInterval(Double(turn) * 100 - 50))
            list.apply(.newTurn, now: t0.addingTimeInterval(Double(turn) * 100))
        }
        XCTAssertEqual(list.items.map(\.title), ["A"])
    }

    func testRestoredPlanNeedsAWholeObservedTurnBeforeRetiring() {
        var list = AgentTaskList(items: [
            AgentTaskItem(id: "step:0", title: "Patch", status: .inProgress),
        ])
        list.apply(.turnEnded, now: t0)   // end of a turn we never saw start
        list.apply(.newTurn, now: t0.addingTimeInterval(10))
        XCTAssertEqual(list.items.count, 1)
        list.apply(.turnEnded, now: t0.addingTimeInterval(70))
        list.apply(.newTurn, now: t0.addingTimeInterval(100))
        XCTAssertTrue(list.isEmpty)
    }

    func testReplayedRolloutRetiresAPlanLaterTurnsAbandoned() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"fix it"}}"#,
            codexPlanLine(callId: "call_p1", steps: [("Read", "completed"), ("Patch", "in_progress")]),
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"what does X do?"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t2"}}"#,
        ]
        let blob = Data((lines.joined(separator: "\n") + "\n").utf8)
        let events = AgentTaskTranscript.scan(blob, startsAtLineBoundary: true)
        XCTAssertEqual(events.filter { $0 == .turnEnded }.count, 2)
        var rebuilt = AgentTaskList.rebuilt(fromTranscript: events, coversWholeTranscript: true, live: AgentTaskList())
        XCTAssertEqual(rebuilt.items.count, 2, "still shown until the next turn starts")
        rebuilt.apply(.newTurn, now: Date())
        XCTAssertTrue(rebuilt.isEmpty)
    }

    func testStopHookEndsTheTurn() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, ["hook_event_name": "UserPromptSubmit", "prompt": "go"])
        reduce(&sessions, todoWrite("toolu_w1", [("A", "completed"), ("B", "in_progress")]))
        reduce(&sessions, ["hook_event_name": "Stop"])
        reduce(&sessions, ["hook_event_name": "UserPromptSubmit", "prompt": "unrelated question"])
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.count, 2)
        // The hooks run in real time here; age the turn past the minimum.
        sessions["s1"]!.agentTasks.apply(.turnEnded, now: Date().addingTimeInterval(60))
        reduce(&sessions, ["hook_event_name": "UserPromptSubmit", "prompt": "another"])
        XCTAssertTrue(sessions["s1"]!.agentTasks.isEmpty)
    }

    func testSessionStartKeepsTheChecklist() {
        // /compact and resume re-fire SessionStart for the same session.
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, todoWrite("toolu_w1", [("A", "in_progress")]))
        reduce(&sessions, ["hook_event_name": "SessionStart", "source": "compact", "cwd": "/tmp/p"])
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.title), ["A"])
        reduce(&sessions, ["hook_event_name": "SessionStart", "source": "resume", "cwd": "/tmp/p"])
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.title), ["A"])
    }

    func testSessionStartAfterClearDropsTheChecklist() {
        // /clear can keep the session id; the conversation (and its plan) is gone.
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, todoWrite("toolu_w1", [("A", "in_progress"), ("B", "pending")]))
        reduce(&sessions, ["hook_event_name": "SessionStart", "source": "clear", "cwd": "/tmp/p"])
        XCTAssertTrue(sessions["s1"]!.agentTasks.isEmpty)
    }

    // MARK: - Subagents

    func testSubagentTaskEventsStayOffTheParentCard() {
        var sessions: [String: SessionSnapshot] = [:]
        var pre = preCreate("toolu_c1", "Child task")
        pre["agent_id"] = "agent-1"
        pre["agent_type"] = "Explore"
        reduce(&sessions, pre)
        var post = postCreate("toolu_c1", "Child task", id: "9")
        post["agent_id"] = "agent-1"
        reduce(&sessions, post)
        var todos = todoWrite("toolu_w1", [("Child todo", "pending")])
        todos["agent_id"] = "agent-1"
        reduce(&sessions, todos)

        XCTAssertTrue(sessions["s1"]!.agentTasks.isEmpty)
        XCTAssertNotNil(sessions["s1"]!.subagents["agent-1"], "the subagent itself is still tracked")
    }

    func testSubagentUpdatesToTheParentsSharedTasksLandOnTheParentCard() {
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, preCreate("toolu_c1", "Write parser"))
        reduce(&sessions, postCreate("toolu_c1", "Write parser", id: "1"))
        reduce(&sessions, preCreate("toolu_c2", "Add tests"))
        reduce(&sessions, postCreate("toolu_c2", "Add tests", id: "2"))

        func asChild(_ payload: [String: Any]) -> [String: Any] {
            var payload = payload
            payload["agent_id"] = "teammate-1"
            payload["agent_type"] = "worker"
            return payload
        }
        // The teammate picks up task 1 and finishes it.
        reduce(&sessions, asChild(preUpdate("toolu_s1", taskId: "1", status: "in_progress")))
        reduce(&sessions, asChild(postUpdate("toolu_s1", taskId: "1", from: "pending", to: "in_progress")))
        reduce(&sessions, asChild(preUpdate("toolu_s2", taskId: "1", status: "completed")))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.status), [.completed, .pending])

        // Its completion of task 2 is blocked by a TaskCompleted hook: undone.
        reduce(&sessions, asChild(preUpdate("toolu_s3", taskId: "2", status: "completed")))
        reduce(&sessions, asChild([
            "hook_event_name": "PostToolUse",
            "tool_name": "TaskUpdate",
            "tool_use_id": "toolu_s3",
            "tool_input": ["taskId": "2", "status": "completed"],
            "tool_response": ["success": false, "taskId": "2", "updatedFields": [String](), "error": "blocked"],
        ]))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.status), [.completed, .pending])

        // Its own task and updates to it stay off the parent card.
        reduce(&sessions, asChild(preCreate("toolu_s4", "Child-only step")))
        reduce(&sessions, asChild(postCreate("toolu_s4", "Child-only step", id: "7")))
        reduce(&sessions, asChild(preUpdate("toolu_s5", taskId: "7", status: "in_progress")))
        XCTAssertEqual(sessions["s1"]!.agentTasks.items.map(\.title), ["Write parser", "Add tests"])
        XCTAssertNotNil(sessions["s1"]!.subagents["teammate-1"])
    }

    func testSidechainTranscriptRowsAreIgnored() throws {
        let line = claudeToolUseLine(id: "toolu_c1", name: "TaskCreate", input: #"{"subject":"Child"}"#, sidechain: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertTrue(AgentTaskTranscript.events(fromLine: json).isEmpty)
    }

    // MARK: - Hook + transcript double delivery

    func testHookAndTranscriptDeliveringSameCallsDoNotDoubleCount() {
        let transcript = Data((claudeTaskTranscript().joined(separator: "\n") + "\n").utf8)

        // Hooks first, then the tail catches up.
        var sessions: [String: SessionSnapshot] = [:]
        reduce(&sessions, preCreate("toolu_c1", "Write parser", activeForm: "Writing parser"))
        reduce(&sessions, postCreate("toolu_c1", "Write parser", id: "1"))
        reduce(&sessions, preCreate("toolu_c2", "Add tests"))
        reduce(&sessions, postCreate("toolu_c2", "Add tests", id: "2"))
        reduce(&sessions, preUpdate("toolu_u1", taskId: "1", status: "in_progress"))
        let viaHooks = sessions["s1"]!.agentTasks
        sessions["s1"]!.agentTasks.apply(JSONLTailer.scanLines(transcript).delta.taskEvents, now: t0)
        XCTAssertEqual(sessions["s1"]!.agentTasks.items, viaHooks.items)

        // Tail first, then (late, async) hooks for the same calls.
        var list = AgentTaskList()
        list.apply(JSONLTailer.scanLines(transcript).delta.taskEvents, now: t0)
        let viaTranscript = list.items
        var lateSessions = ["s1": SessionSnapshot()]
        lateSessions["s1"]!.agentTasks = list
        reduce(&lateSessions, postCreate("toolu_c1", "Write parser", id: "1"))
        reduce(&lateSessions, preCreate("toolu_c2", "Add tests"))
        reduce(&lateSessions, postUpdate("toolu_u1", taskId: "1", from: "pending", to: "in_progress"))
        XCTAssertEqual(lateSessions["s1"]!.agentTasks.items.count, 2)
        XCTAssertEqual(lateSessions["s1"]!.agentTasks.items.map(\.status), viaTranscript.map(\.status))
        XCTAssertEqual(viaTranscript.map(\.status), [.inProgress, .pending])
    }

    // MARK: - Transcript row shapes

    func testClaudeTranscriptRowShapes() throws {
        func events(_ line: String) throws -> [AgentTaskEvent] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return AgentTaskTranscript.events(fromLine: json)
        }
        XCTAssertEqual(try events(claudePromptLine("Refactor the parser")), [.newTurn])
        XCTAssertEqual(try events(#"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#), [])
        XCTAssertEqual(try events(#"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"Summary of the conversation"}}"#), [])
        XCTAssertEqual(
            try events(claudeResultLine(toolUseId: "toolu_c1", text: "Task #1 created successfully: A", toolUseResult: #"{"task":{"id":"1","subject":"A"}}"#)),
            [.created(opId: "toolu_c1", taskId: "1", title: "A", activeForm: nil)]
        )
        // TaskGet echoes a task *with* status — a read, not a create.
        XCTAssertEqual(
            try events(claudeResultLine(toolUseId: "toolu_g1", text: "Task #1: A", toolUseResult: #"{"task":{"id":"1","subject":"A","status":"pending","blocks":[]}}"#)),
            []
        )
        XCTAssertEqual(
            try events(claudeResultLine(toolUseId: "toolu_u9", text: "blocked", toolUseResult: #"{"success":false,"taskId":"1","updatedFields":[],"error":"blocked"}"#)),
            [.opFailed(opId: "toolu_u9")]
        )
        XCTAssertEqual(
            try events(claudeResultLine(toolUseId: "toolu_u1", text: "Updated task #1 status", toolUseResult: #"{"success":true,"taskId":"1","updatedFields":["status"],"statusChange":{"from":"pending","to":"completed"}}"#)),
            [.update(opId: "toolu_u1", taskId: "1", change: AgentTaskChange(status: .completed), expectedFrom: .pending)]
        )
        // Several results in one row: toolUseResult is ambiguous, the text is not.
        let multi = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_a","type":"tool_result","content":"Task #5 created successfully: Five"},{"tool_use_id":"toolu_b","type":"tool_result","content":"ok","is_error":true}]},"toolUseResult":{"task":{"id":"4","subject":"wrong"}}}"#
        XCTAssertEqual(try events(multi), [
            .createdPerText(opId: "toolu_a", taskId: "5", title: "Five"),
            .opFailed(opId: "toolu_b"),
        ])
    }

    func testTextOnlyCreateResultCompletesADraftButNeverAddsARow() throws {
        func events(_ line: String) throws -> [AgentTaskEvent] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return AgentTaskTranscript.events(fromLine: json)
        }
        // An MCP tool whose text result happens to read like TaskCreate's.
        let mcpResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_mcp","type":"tool_result","content":[{"type":"text","text":"Task #42 created successfully: sync tickets"}]}]}}"#
        var list = AgentTaskList()
        list.apply(.replace(opId: "w1", items: [AgentTaskDraft(title: "A", status: .completed)]), now: t0)
        list.apply(try events(mcpResult), now: t0)
        XCTAssertEqual(list.items.map(\.title), ["A"], "no ghost row from someone else's text")
        list.apply(.newTurn, now: t0)
        XCTAssertTrue(list.isEmpty, "and nothing pending keeps a finished list from retiring")

        // A real TaskCreate answered in a multi-result row: its draft gets the id.
        let call = claudeToolUseLine(id: "toolu_a", name: "TaskCreate", input: #"{"subject":"Five"}"#)
        let multi = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_a","type":"tool_result","content":"Task #5 created successfully: Five"},{"tool_use_id":"toolu_b","type":"tool_result","content":"ok"}]}}"#
        list.apply(try events(call) + events(multi), now: t0)
        list.apply(.update(opId: "u5", taskId: "5", change: AgentTaskChange(status: .inProgress), expectedFrom: nil), now: t0)
        XCTAssertEqual(list.items.map(\.taskId), ["5"])
        XCTAssertEqual(list.items.map(\.status), [.inProgress])
    }

    func testIgnoredTextResultLeavesTheStructuredResultFree() {
        // The text row came first with no draft to complete; the call's own
        // structured result (a late hook) must still apply.
        var list = AgentTaskList()
        list.apply(.createdPerText(opId: "c1", taskId: "1", title: "A"), now: t0)
        list.apply(.created(opId: "c1", taskId: "1", title: "A", activeForm: nil), now: t0)
        XCTAssertEqual(list.items.map(\.title), ["A"])
    }

    // MARK: - Completion linger

    func testCompletionLingerThenHides() {
        var list = AgentTaskList()
        list.apply(.replace(opId: "w1", items: [AgentTaskDraft(title: "A", status: .inProgress)]), now: t0)
        XCTAssertNil(list.completedAt)
        XCTAssertTrue(list.isVisible(now: t0.addingTimeInterval(3_600)), "open lists never time out")

        let done = t0.addingTimeInterval(10)
        list.apply(.replace(opId: "w2", items: [AgentTaskDraft(title: "A", status: .completed)]), now: done)
        XCTAssertEqual(list.completedAt, done)
        XCTAssertTrue(list.isVisible(now: done.addingTimeInterval(1)))
        XCTAssertFalse(list.isVisible(now: done.addingTimeInterval(AgentTaskList.completedLinger)))

        // A duplicate all-done snapshot must not restart the linger.
        list.apply(.replace(opId: "w3", items: [AgentTaskDraft(title: "A", status: .completed)]), now: done.addingTimeInterval(5))
        XCTAssertEqual(list.completedAt, done)

        list.apply(.replace(opId: "w4", items: [AgentTaskDraft(title: "B", status: .pending)]), now: done)
        XCTAssertNil(list.completedAt)
    }

    // MARK: - Attach-time rebuild

    func testRebuildFromWholeTranscriptReplacesStaleRows() {
        let stale = AgentTaskList(items: [AgentTaskItem(id: "step:0", title: "Old", status: .inProgress)])
        let events = JSONLTailer.scanLines(Data((claudeTaskTranscript().joined(separator: "\n") + "\n").utf8)).delta.taskEvents
        let rebuilt = AgentTaskList.rebuilt(fromTranscript: events, coversWholeTranscript: true, live: stale)
        XCTAssertEqual(rebuilt.items.map(\.title), ["Write parser", "Add tests"])
    }

    func testRebuildFromTailWindowKeepsRowsCreatedBeforeIt() {
        let live = AgentTaskList(items: [
            AgentTaskItem(id: "task:1", taskId: "1", createOpId: "toolu_c1", title: "Early", status: .inProgress),
        ])
        let window: [AgentTaskEvent] = [
            .update(opId: "u9", taskId: "1", change: AgentTaskChange(status: .completed), expectedFrom: nil),
            .create(opId: "toolu_c2", title: "Late", activeForm: nil),
            .created(opId: "toolu_c2", taskId: "2", title: "Late", activeForm: nil),
        ]
        let rebuilt = AgentTaskList.rebuilt(fromTranscript: window, coversWholeTranscript: false, live: live)
        XCTAssertEqual(rebuilt.items.map(\.title), ["Early", "Late"])
        XCTAssertEqual(rebuilt.items.map(\.status), [.completed, .pending])
    }

    func testRebuildWithoutOperationsKeepsLiveAndReplayedCompletionDoesNotFlash() {
        let live = AgentTaskList(items: [AgentTaskItem(id: "step:0", title: "A", status: .inProgress)])
        XCTAssertEqual(AgentTaskList.rebuilt(fromTranscript: [.newTurn], coversWholeTranscript: true, live: live), live)

        let finished = AgentTaskList.rebuilt(
            fromTranscript: [.replace(opId: "w1", items: [AgentTaskDraft(title: "A", status: .completed)])],
            coversWholeTranscript: true,
            live: AgentTaskList()
        )
        XCTAssertTrue(finished.isAllCompleted)
        XCTAssertFalse(finished.isVisible(now: Date()), "a list finished before attach must not show 'all done'")
    }

    // MARK: - Backfill scanner

    func testBackfillScanSkipsPartialHeadOversizedRowsAndUnterminatedTail() {
        let lines = claudeTaskTranscript()
        let oversized = claudeToolUseLine(
            id: "toolu_big", name: "TaskCreate",
            input: "{\"subject\":\"Huge\",\"description\":\"\(String(repeating: "x", count: 2_000))\"}"
        )
        // Window cut mid-row, an oversized row, the real rows, then a row still being written.
        let blob = "ated successfully\"}]}\n" + oversized + "\n" + lines.joined(separator: "\n") + "\n" + "{\"type\":\"user\",\"mess"
        let events = AgentTaskTranscript.scan(Data(blob.utf8), startsAtLineBoundary: false, maxLineBytes: 1_024)
        var list = AgentTaskList()
        list.apply(events, now: t0)
        XCTAssertEqual(list.items.map(\.title), ["Write parser", "Add tests"])
        XCTAssertEqual(list.items.map(\.status), [.inProgress, .pending])
    }

    func testBackfillPrefilterMatchesOnlyRelevantRows() {
        func matches(_ line: String) -> Bool {
            let bytes = Array(line.utf8)
            return bytes.withUnsafeBufferPointer { AgentTaskTranscript.mayCarryTaskEvent($0.baseAddress!, length: $0.count) }
        }
        XCTAssertTrue(matches(claudePromptLine("hi")))
        XCTAssertTrue(matches(claudeToolUseLine(id: "t", name: "TodoWrite", input: #"{"todos":[]}"#)))
        XCTAssertTrue(matches(codexPlanLine(callId: "c", steps: [("A", "pending")])))
        XCTAssertFalse(matches(claudeToolUseLine(id: "t", name: "Bash", input: #"{"command":"ls"}"#)))
        XCTAssertFalse(matches(claudeResultLine(toolUseId: "t", text: "file contents", toolUseResult: #"{"stdout":"x"}"#)))
        // Every spelling the live parser accepts (forks rename the tool).
        for name in ["todo_write", "write_todos", "todowrite", "WriteTodos", "task_create", "TASKUPDATE", "update-plan"] {
            XCTAssertTrue(matches(claudeToolUseLine(id: "t", name: name, input: #"{"todos":[]}"#)), name)
        }
        XCTAssertFalse(matches(claudeToolUseLine(id: "t", name: "todo_read", input: #"{}"#)))
        XCTAssertFalse(matches(claudeToolUseLine(id: "t", name: "TaskCreateAndRun", input: #"{}"#)))
    }

    func testBackfillReplaysAForkTranscriptThatSpellsTheToolDifferently() {
        let lines = [
            claudePromptLine("plan it"),
            claudeToolUseLine(id: "toolu_w1", name: "write_todos", input: #"{"todos":[{"description":"Scan","status":"completed"},{"description":"Fix","status":"in_progress"}]}"#),
        ]
        let events = AgentTaskTranscript.scan(Data((lines.joined(separator: "\n") + "\n").utf8), startsAtLineBoundary: true)
        let rebuilt = AgentTaskList.rebuilt(
            fromTranscript: events,
            coversWholeTranscript: true,
            live: AgentTaskList(items: [AgentTaskItem(id: "step:0", title: "Stale", status: .pending)])
        )
        XCTAssertEqual(rebuilt.items.map(\.title), ["Scan", "Fix"])
    }

    func testTranscriptOfOnlyPromptsAndUnrelatedFailuresKeepsTheLiveList() {
        // A Bash call failed (is_error) and a prompt was typed: nothing in
        // there can build a checklist, so what hooks built must survive.
        let live = AgentTaskList(items: [AgentTaskItem(id: "step:0", title: "A", status: .inProgress)])
        let events: [AgentTaskEvent] = [.newTurn, .opFailed(opId: "toolu_bash"), .createdPerText(opId: "toolu_mcp", taskId: "9", title: nil)]
        XCTAssertFalse(events.contains(where: \.buildsList))
        XCTAssertEqual(AgentTaskList.rebuilt(fromTranscript: events, coversWholeTranscript: true, live: live), live)
    }

    func testScanFileStopsAtTheTailerOffset() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-agent-tasks-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let head = claudeTaskTranscript().joined(separator: "\n") + "\n"
        let appended = claudeToolUseLine(id: "toolu_c3", name: "TaskCreate", input: #"{"subject":"After attach"}"#) + "\n"
        try (head + appended).write(to: url, atomically: true, encoding: .utf8)

        let backfill = try XCTUnwrap(AgentTaskTranscript.scanFile(atPath: url.path, endOffset: UInt64(head.utf8.count)))
        XCTAssertTrue(backfill.coversWholeFile)
        var list = AgentTaskList()
        list.apply(backfill.events, now: t0)
        XCTAssertEqual(list.items.map(\.title), ["Write parser", "Add tests"], "bytes past the tail offset belong to the tailer")

        let window = try XCTUnwrap(AgentTaskTranscript.scanFile(atPath: url.path, endOffset: UInt64(head.utf8.count), maxBytes: 64))
        XCTAssertFalse(window.coversWholeFile)
    }

    // MARK: - Persistence

    func testCodableRoundTripKeepsItemsAndCompletion() throws {
        var list = AgentTaskList()
        list.apply([
            .created(opId: "c1", taskId: "1", title: "A", activeForm: "Doing A"),
            .update(opId: "u1", taskId: "1", change: AgentTaskChange(status: .completed), expectedFrom: nil),
        ], now: t0)
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(AgentTaskList.self, from: data)
        XCTAssertEqual(decoded, list)
        XCTAssertEqual(decoded.items.first?.activeForm, "Doing A")
        XCTAssertEqual(decoded.completedAt, t0)
    }

    func testUnknownPersistedStatusDecodesAsPending() throws {
        let json = #"{"items":[{"id":"a","title":"A","status":"in_progress"},{"id":"b","title":"B","status":"awaiting_review"},{"id":"c","title":"C","status":"done"}]}"#
        let decoded = try JSONDecoder().decode(AgentTaskList.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.items.map(\.status), [.inProgress, .pending, .completed])
        // Encoding still writes the canonical raw values.
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertTrue(reencoded.contains(#""status":"in_progress""#))
        XCTAssertTrue(reencoded.contains(#""status":"completed""#))
    }

    func testStatusVocabularies() {
        XCTAssertEqual(AgentTaskStatus.parse("in-progress"), .status(.inProgress))
        XCTAssertEqual(AgentTaskStatus.parse("DONE"), .status(.completed))
        XCTAssertEqual(AgentTaskStatus.parse("cancelled"), .removed)
        XCTAssertEqual(AgentTaskStatus.parse("weird"), .unknown)
        XCTAssertEqual(AgentTaskStatus.parse(nil), .unknown)
        XCTAssertEqual(AgentTaskTool(toolName: "write_todos"), .todoSnapshot)
        XCTAssertEqual(AgentTaskTool(toolName: "todo_write"), .todoSnapshot)
        XCTAssertNil(AgentTaskTool(toolName: "TaskGet"))
        XCTAssertNil(AgentTaskTool(toolName: "mcp__x__task_create"))
    }

    // MARK: - Helpers

    private func reduce(_ sessions: inout [String: SessionSnapshot], _ payload: [String: Any]) {
        var json = payload
        if json["session_id"] == nil { json["session_id"] = "s1" }
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard let event = HookEvent(from: data) else {
            return XCTFail("invalid hook payload \(json)")
        }
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
    }

    private func preCreate(_ opId: String, _ subject: String, activeForm: String? = nil) -> [String: Any] {
        var input: [String: Any] = ["subject": subject, "description": "details"]
        if let activeForm { input["activeForm"] = activeForm }
        return ["hook_event_name": "PreToolUse", "tool_name": "TaskCreate", "tool_use_id": opId, "tool_input": input]
    }

    private func postCreate(_ opId: String, _ subject: String, id: String) -> [String: Any] {
        [
            "hook_event_name": "PostToolUse",
            "tool_name": "TaskCreate",
            "tool_use_id": opId,
            "tool_input": ["subject": subject],
            "tool_response": ["task": ["id": id, "subject": subject]],
        ]
    }

    private func preUpdate(_ opId: String, taskId: String, status: String) -> [String: Any] {
        [
            "hook_event_name": "PreToolUse",
            "tool_name": "TaskUpdate",
            "tool_use_id": opId,
            "tool_input": ["taskId": taskId, "status": status],
        ]
    }

    private func postUpdate(_ opId: String, taskId: String, from: String, to: String) -> [String: Any] {
        [
            "hook_event_name": "PostToolUse",
            "tool_name": "TaskUpdate",
            "tool_use_id": opId,
            "tool_input": ["taskId": taskId, "status": to],
            "tool_response": [
                "success": true, "taskId": taskId, "updatedFields": ["status"],
                "statusChange": ["from": from, "to": to],
            ],
        ]
    }

    private func todoWrite(_ opId: String, _ todos: [(String, String)]) -> [String: Any] {
        [
            "hook_event_name": "PreToolUse",
            "tool_name": "TodoWrite",
            "tool_use_id": opId,
            "tool_input": ["todos": todos.map { ["content": $0.0, "status": $0.1, "activeForm": "\($0.0)…ing"] }],
        ]
    }

    /// Row shapes as Claude Code 2.1 writes them (checked against real transcripts).
    private func claudeTaskTranscript() -> [String] {
        [
            claudePromptLine("Refactor the parser"),
            claudeToolUseLine(id: "toolu_c1", name: "TaskCreate", input: #"{"subject":"Write parser","description":"d","activeForm":"Writing parser"}"#),
            claudeResultLine(toolUseId: "toolu_c1", text: "Task #1 created successfully: Write parser", toolUseResult: #"{"task":{"id":"1","subject":"Write parser"}}"#),
            claudeToolUseLine(id: "toolu_c2", name: "TaskCreate", input: #"{"subject":"Add tests","description":"d"}"#),
            claudeResultLine(toolUseId: "toolu_c2", text: "Task #2 created successfully: Add tests", toolUseResult: #"{"task":{"id":"2","subject":"Add tests"}}"#),
            claudeToolUseLine(id: "toolu_u1", name: "TaskUpdate", input: #"{"taskId":"1","status":"in_progress"}"#),
            claudeResultLine(toolUseId: "toolu_u1", text: "Updated task #1 status", toolUseResult: #"{"success":true,"taskId":"1","updatedFields":["status"],"statusChange":{"from":"pending","to":"in_progress"}}"#),
        ]
    }

    private func claudePromptLine(_ text: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"p1"}"#
    }

    private func claudeToolUseLine(id: String, name: String, input: String, sidechain: Bool = false) -> String {
        #"{"parentUuid":"x","isSidechain":\#(sidechain),"message":{"model":"claude","type":"message","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]},"type":"assistant","uuid":"a1"}"#
    }

    private func claudeResultLine(toolUseId: String, text: String, toolUseResult: String) -> String {
        #"{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(toolUseId)","type":"tool_result","content":"\#(text)"}]},"uuid":"r1","toolUseResult":\#(toolUseResult)}"#
    }

    private func codexPlanLine(callId: String, steps: [(String, String)]) -> String {
        let plan = steps.map { #"{\"step\":\"\#($0.0)\",\"status\":\"\#($0.1)\"}"# }.joined(separator: ",")
        return #"{"timestamp":"2026-06-25T01:40:57.835Z","ordinal":1,"type":"response_item","payload":{"type":"function_call","id":"fc_1","name":"update_plan","arguments":"{\"plan\":[\#(plan)]}","call_id":"\#(callId)"}}"#
    }
}
