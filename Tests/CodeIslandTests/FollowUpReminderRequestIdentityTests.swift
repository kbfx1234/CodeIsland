import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A follow-up reminder belongs to one request. Re-evaluating the queue
/// (`showNextPending`, another session's request arriving) must not restart
/// it, and a session's *next* request must not inherit the attempts or the
/// silence of the one before it.
@MainActor
final class FollowUpReminderRequestIdentityTests: XCTestCase {
    private var appState: AppState!
    private var followUps: FollowUpReminderController!
    private var now = Date(timeIntervalSinceReferenceDate: 50_000)
    private var fired: [FollowUpReminder] = []
    private var pending: [Task<Data, Never>] = []
    private var saved: [String: Any?] = [:]
    private let keys = [
        SettingsKey.autoExpandOnPermission, SettingsKey.autoExpandOnQuestion,
        SettingsKey.smartSuppress, SettingsKey.completionNotificationStyle,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)
        now = Date(timeIntervalSinceReferenceDate: 50_000)
        fired = []
        pending = []
        appState = AppState()
        followUps = appState.followUps
        followUps.armsTimer = false
        followUps.clock = { [unowned self] in self.now }
        followUps.intervalProvider = { 60 }
        followUps.isHeldBack = { false }
        followUps.isPointerOverPanel = { false }
        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        followUps.playSound = { _ in }
        followUps.addReminderHandler { [unowned self] in self.fired.append($0) }
    }

    override func tearDown() async throws {
        // Every waiter, subagents' included, so no pending hook task hangs.
        let waiters = appState.permissionQueue.map(\.event) + appState.questionQueue.map(\.event)
        for event in waiters {
            appState.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        // `try?`: a stuck request is already recorded as a failure; the
        // rest of the teardown must still run so the defaults are restored.
        for t in pending { _ = try? await awaitValue(of: t) }
        followUps = nil
        appState = nil
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        try await super.tearDown()
    }

    // MARK: - Re-evaluating the queue keeps the clock

    /// The 3-attempt cap must survive an unrelated session's approval arriving
    /// (which re-runs `showNextPending` and re-syncs the queue).
    func testCapIsNotResetByAnotherSessionsRequest() async throws {
        try await requestApproval("A")
        appState.surface = .collapsed
        for _ in 0..<3 { await advance(60) }
        XCTAssertEqual(fired.map(\.attempt), [1, 2, 3])
        // Card was reopened by reminder; user closes island again.
        appState.surface = .collapsed
        // Another session asks for approval while the island is collapsed.
        try await requestApproval("B")
        fired = []
        await advance(60)
        XCTAssertFalse(fired.contains { $0.sessionId == "A" }, "A already exhausted its 3 attempts")
    }

    /// Jumping to a session silences it; a later `showNextPending` must not
    /// bring its reminders back.
    func testJumpSilenceSurvivesShowNextPending() async throws {
        try await requestApproval("J")
        NotificationCenter.default.post(name: .codeIslandDidJumpToSession, object: nil, userInfo: ["sessionId": "J"])
        appState.showNextPending()
        await advance(60)
        XCTAssertEqual(fired, [], "jump should have stopped J's reminders")
    }

    /// A `showNextPending` that runs more often than the interval (a busy
    /// background subagent) must not keep pushing the first reminder out.
    func testFrequentShowNextPendingDoesNotPostponeForever() async throws {
        try await requestApproval("P")
        for _ in 0..<10 {
            now = now.addingTimeInterval(50)
            appState.showNextPending()
            await followUps.tick(now: now)
        }
        XCTAssertFalse(fired.isEmpty, "a 60s reminder should have fired within 500s")
    }

    // MARK: - One entry per request

    /// Two approvals from one session (parallel tools, a subagent): the first
    /// one was dealt with by jumping to the terminal, then answered. The
    /// second is a new request and is reminded about from scratch.
    func testSessionsNextApprovalDoesNotInheritTheSilence() async throws {
        try await requestApproval("S", command: "echo one", toolUseId: "tu-1")
        try await requestApproval("S", command: "echo two", toolUseId: "tu-2")
        XCTAssertEqual(appState.permissionQueue.count, 2)
        NotificationCenter.default.post(name: .codeIslandDidJumpToSession, object: nil, userInfo: ["sessionId": "S"])
        await advance(30)
        appState.approvePermission(expectedSessionId: "S")   // the first one
        XCTAssertEqual(appState.permissionQueue.count, 1)
        appState.surface = .collapsed

        await advance(59)
        XCTAssertEqual(fired, [], "the new request's clock starts when it becomes the session's")
        await advance(1)
        XCTAssertEqual(fired.map(\.sessionId), ["S"])
        XCTAssertEqual(fired.map(\.attempt), [1])
        XCTAssertEqual(fired.first?.requestId, appState.permissionQueue.first?.id.uuidString)
    }

    /// Same, with the attempts spent: the next request gets all three.
    func testSessionsNextApprovalDoesNotInheritSpentAttempts() async throws {
        try await requestApproval("E", command: "echo one", toolUseId: "tu-e1")
        try await requestApproval("E", command: "echo two", toolUseId: "tu-e2")
        for _ in 0..<3 { await advance(60) }
        XCTAssertEqual(fired.map(\.attempt), [1, 2, 3])

        appState.approvePermission(expectedSessionId: "E")
        fired = []
        for _ in 0..<4 { await advance(60) }
        XCTAssertEqual(fired.map(\.attempt), [1, 2, 3])
    }

    /// A replay of the same request (same tool_use_id and input) is the same
    /// wait: its reminder keeps the clock of the first arrival.
    func testReplayedApprovalKeepsItsReminderClock() async throws {
        try await requestApproval("R", command: "echo same", toolUseId: "tu-replay")
        let id = try XCTUnwrap(appState.permissionQueue.first?.id)
        await advance(30)
        try await requestApproval("R", command: "echo same", toolUseId: "tu-replay")
        XCTAssertEqual(appState.permissionQueue.count, 1, "merged as a replay")
        XCTAssertEqual(appState.permissionQueue.first?.id, id, "a replay keeps the request's identity")
        appState.surface = .collapsed

        await advance(30)
        XCTAssertEqual(fired.map(\.sessionId), ["R"], "due a minute after the first arrival")
    }

    /// Questions: a session's next question (the first was answered while a
    /// second one from a subagent waited) starts over too.
    func testSessionsNextQuestionDoesNotInheritTheSilence() async throws {
        try await ask("Q", agentId: nil)
        try await ask("Q", agentId: "sub-1")
        XCTAssertEqual(appState.questionQueue.count, 2)
        NotificationCenter.default.post(name: .codeIslandDidJumpToSession, object: nil, userInfo: ["sessionId": "Q"])
        appState.skipQuestion(expectedSessionId: "Q")
        XCTAssertEqual(appState.questionQueue.count, 1)
        appState.surface = .collapsed

        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.question])
        XCTAssertEqual(fired.first?.requestId, appState.questionQueue.first?.id.uuidString)
    }

    // MARK: - Helpers

    private func advance(_ s: TimeInterval) async {
        now = now.addingTimeInterval(s)
        await followUps.tick(now: now)
    }

    private func requestApproval(_ sid: String, command: String = "echo", toolUseId: String? = nil) async throws {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "Bash",
            "tool_input": ["command": command],
        ]
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        let e = try event(payload)
        pending.append(await startHookRequest { [appState] in appState!.handlePermissionRequest(e, continuation: $0) })
    }

    private func ask(_ sid: String, agentId: String?) async throws {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]],
        ]
        if let agentId { payload["agent_id"] = agentId }
        let e = try event(payload)
        pending.append(await startHookRequest { [appState] in appState!.handleAskUserQuestion(e, continuation: $0) })
    }

    private func event(_ p: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: p)))
    }
}
