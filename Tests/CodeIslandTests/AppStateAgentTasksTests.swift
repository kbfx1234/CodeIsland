import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateAgentTasksTests: XCTestCase {
    func testTranscriptDeltaUpdatesChecklist() {
        let appState = AppState()
        let sessionId = "codex-plan-delta"
        var session = SessionSnapshot()
        session.source = "codex"
        appState.sessions[sessionId] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            taskEvents: [.replace(opId: "call_1", items: [
                AgentTaskDraft(title: "Inspect", status: .completed),
                AgentTaskDraft(title: "Rewrite", status: .inProgress),
            ])]
        ))

        let tasks = appState.sessions[sessionId]?.agentTasks
        XCTAssertEqual(tasks?.items.map(\.title), ["Inspect", "Rewrite"])
        XCTAssertEqual(tasks?.current?.title, "Rewrite")
    }

    func testAttachBackfillsChecklistFromTranscriptHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-agent-task-backfill-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Old plan\",\"status\":\"completed\"}]}","call_id":"call_a"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Read\",\"status\":\"completed\"},{\"step\":\"Patch\",\"status\":\"in_progress\"},{\"step\":\"Test\",\"status\":\"pending\"}]}","call_id":"call_b"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let appState = AppState()
        let sessionId = "codex-plan-backfill"
        var session = SessionSnapshot()
        session.source = "codex"
        session.transcriptPath = url.path
        appState.sessions[sessionId] = session
        defer { appState.detachTranscriptTailer(sessionId: sessionId) }

        appState.attachTranscriptTailerIfNeeded(sessionId: sessionId)
        // The scan runs detached and lands back on the main actor.
        var attempts = 0
        while appState.sessions[sessionId]?.agentTasks.isEmpty != false, attempts < 150 {
            attempts += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let tasks = try XCTUnwrap(appState.sessions[sessionId]?.agentTasks)
        XCTAssertEqual(tasks.items.map(\.title), ["Read", "Patch", "Test"])
        XCTAssertEqual(tasks.completedCount, 1)
        XCTAssertNil(appState.pendingAgentTaskBackfills[sessionId])
    }

    func testAttachWhileTheLastPlanRowIsBeingWrittenStillShowsThePlan() async throws {
        // The rollout's final update_plan is half-written when CodeIsland
        // attaches. The backfill skips unterminated rows, and a tailer that
        // started at the file's end read only the row's tail — the plan was
        // lost until Codex happened to update it again.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-agent-task-gap-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let head = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"# + "\n"
        let plan = #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Read\",\"status\":\"completed\"},{\"step\":\"Patch\",\"status\":\"in_progress\"}]}","call_id":"call_gap"}}"# + "\n"
        let cut = plan.index(plan.startIndex, offsetBy: plan.count / 2)
        try (head + String(plan[..<cut])).write(to: url, atomically: true, encoding: .utf8)

        let appState = AppState()
        let sessionId = "codex-plan-gap"
        var session = SessionSnapshot()
        session.source = "codex"
        session.transcriptPath = url.path
        appState.sessions[sessionId] = session
        defer { appState.detachTranscriptTailer(sessionId: sessionId) }

        appState.attachTranscriptTailerIfNeeded(sessionId: sessionId)
        try await Task.sleep(nanoseconds: 150_000_000)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(plan[cut...]).utf8))
        try handle.close()

        var attempts = 0
        while appState.sessions[sessionId]?.agentTasks.isEmpty != false, attempts < 150 {
            attempts += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(appState.sessions[sessionId]?.agentTasks.items.map(\.title), ["Read", "Patch"])
    }

    func testReplayOfAReplacedTranscriptDoesNotFlashAnOldFinishedPlan() {
        let appState = AppState()
        let sessionId = "codex-replaced-rollout"
        var session = SessionSnapshot()
        session.source = "codex"
        appState.sessions[sessionId] = session

        // The tailer re-read a replaced rollout from byte 0: a plan finished
        // long ago is history, not a completion that just happened.
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            taskEvents: [.newTurn, .replace(opId: "call_old", items: [
                AgentTaskDraft(title: "Read", status: .completed),
                AgentTaskDraft(title: "Patch", status: .completed),
            ])],
            replaysWholeFile: true
        ))
        let tasks = appState.sessions[sessionId]?.agentTasks
        XCTAssertEqual(tasks?.isAllCompleted, true)
        XCTAssertEqual(tasks?.isVisible(now: Date()), false, "no 'all done' linger for history")

        // A plan finished live does linger.
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            taskEvents: [
                .newTurn,
                .replace(opId: "call_new", items: [AgentTaskDraft(title: "Ship", status: .inProgress)]),
                .replace(opId: "call_done", items: [AgentTaskDraft(title: "Ship", status: .completed)]),
            ]
        ))
        XCTAssertEqual(appState.sessions[sessionId]?.agentTasks.isVisible(now: Date()), true)
    }

    func testBackfillReplaysTailEventsThatLandedDuringTheScan() {
        let history: [AgentTaskEvent] = [
            .create(opId: "toolu_c1", title: "Write parser", activeForm: nil),
            .created(opId: "toolu_c1", taskId: "1", title: "Write parser", activeForm: nil),
        ]
        // The tail delivered a newer update while the scan was running; the
        // live list already has it, the rebuilt one must keep it too.
        let buffered: [AgentTaskEvent] = [
            .update(opId: "toolu_u1", taskId: "1", change: AgentTaskChange(status: .completed), expectedFrom: nil),
        ]
        var live = AgentTaskList()
        live.apply(buffered, now: Date())

        let now = Date()
        let rebuilt = AppState.agentTasksAfterBackfill(
            live: live,
            backfill: AgentTaskTranscript.Backfill(events: history, coversWholeFile: true),
            bufferedEvents: buffered,
            now: now
        )
        XCTAssertEqual(rebuilt.items.map(\.title), ["Write parser"])
        XCTAssertEqual(rebuilt.items.map(\.status), [.completed])
        XCTAssertEqual(rebuilt.completedAt, now, "a completion seen live still gets its 'all done' moment")
    }

    func testBackfillWithoutOperationsLeavesLiveListAlone() {
        var live = AgentTaskList()
        live.apply(.replace(opId: "w1", items: [AgentTaskDraft(title: "A", status: .completed)]), now: Date())
        let result = AppState.agentTasksAfterBackfill(
            live: live,
            backfill: AgentTaskTranscript.Backfill(events: [.newTurn], coversWholeFile: true),
            bufferedEvents: [.newTurn],
            now: Date()
        )
        XCTAssertEqual(result, live, "replaying a prompt the live list already saw must not clear it")
    }

    func testBackfillOfUnrelatedToolFailuresLeavesLiveListAlone() {
        // Gemini-style list built by write_todos hooks; the transcript scan
        // only found a failing Bash call. Replaying that from empty used to
        // wipe the list.
        var live = AgentTaskList()
        live.apply(.replace(opId: "w1", items: [
            AgentTaskDraft(title: "A", status: .completed),
            AgentTaskDraft(title: "B", status: .inProgress),
        ]), now: Date())
        let result = AppState.agentTasksAfterBackfill(
            live: live,
            backfill: AgentTaskTranscript.Backfill(
                events: [.newTurn, .opFailed(opId: "toolu_bash")],
                coversWholeFile: true
            ),
            bufferedEvents: [],
            now: Date()
        )
        XCTAssertEqual(result, live)
    }

    func testIdleCardShowsProgressButNoWorkingCaption() {
        var tasks = AgentTaskList()
        tasks.apply(.replace(opId: "w1", items: [
            AgentTaskDraft(title: "Read", status: .completed),
            AgentTaskDraft(title: "Patch", activeForm: "Patching", status: .inProgress),
            AgentTaskDraft(title: "Test", status: .pending),
        ]), now: Date())
        XCTAssertEqual(AgentTaskProgressView.caption(tasks: tasks, agentIsIdle: false), .working("Patching"))
        XCTAssertNil(AgentTaskProgressView.caption(tasks: tasks, agentIsIdle: true))

        var unclaimed = AgentTaskList()
        unclaimed.apply(.replace(opId: "w2", items: [AgentTaskDraft(title: "Test", status: .pending)]), now: Date())
        XCTAssertEqual(AgentTaskProgressView.caption(tasks: unclaimed, agentIsIdle: false), .next("Test"))
        XCTAssertNil(AgentTaskProgressView.caption(tasks: unclaimed, agentIsIdle: true))

        var done = AgentTaskList()
        done.apply(.replace(opId: "w3", items: [AgentTaskDraft(title: "Test", status: .completed)]), now: Date())
        XCTAssertEqual(AgentTaskProgressView.caption(tasks: done, agentIsIdle: true), .allDone)
    }

    func testPersistedSessionKeepsChecklistAndDecodesOlderFiles() throws {
        let legacy = """
        {"sessionId":"s","source":"claude","startTime":"2026-04-09T10:00:00Z","lastActivity":"2026-04-09T10:01:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(PersistedSession.self, from: Data(legacy.utf8)).agentTasks)

        var snapshot = SessionSnapshot()
        snapshot.agentTasks.apply([
            .created(opId: "c1", taskId: "1", title: "A", activeForm: "Doing A"),
            .update(opId: "u1", taskId: "1", change: AgentTaskChange(status: .inProgress), expectedFrom: nil),
        ], now: Date())
        let current = """
        {"sessionId":"s","source":"claude","startTime":"2026-04-09T10:00:00Z","lastActivity":"2026-04-09T10:01:00Z",
         "agentTasks":\(String(decoding: try JSONEncoder().encode(snapshot.agentTasks), as: UTF8.self))}
        """
        let decoded = try decoder.decode(PersistedSession.self, from: Data(current.utf8))
        XCTAssertEqual(decoded.agentTasks, snapshot.agentTasks)
        XCTAssertEqual(decoded.agentTasks?.current?.progressLabel, "Doing A")
    }
}
