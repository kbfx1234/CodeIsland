import XCTest
@testable import CodeIsland
import CodeIslandCore

/// What the island shows after the queues are re-evaluated
/// (`showNextPending`): a completion card must not get stuck behind a
/// request that stays hidden.
@MainActor
final class PanelCardFlowTests: XCTestCase {
    private var appState: AppState!
    private var pending: [Task<Data, Never>] = []
    private var saved: [String: Any?] = [:]
    private let keys = [
        SettingsKey.autoExpandOnPermission, SettingsKey.autoExpandOnQuestion,
        SettingsKey.smartSuppress, SettingsKey.completionNotificationStyle,
        SettingsKey.followUpReminderMinutes,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set("expand", forKey: SettingsKey.completionNotificationStyle)
        UserDefaults.standard.set(0, forKey: SettingsKey.followUpReminderMinutes)
        pending = []
        appState = AppState()
        // The real card stays up 5 s; the flow is the same at 50 ms.
        appState.completionAutoCollapseDelay = 0.05
    }

    override func tearDown() async throws {
        let waiters = appState.permissionQueue.map(\.event) + appState.questionQueue.map(\.event)
        for event in waiters {
            appState.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        // `try?`: a stuck request is already recorded as a failure; the
        // rest of the teardown must still run so the defaults are restored.
        for t in pending { _ = try? await awaitValue(of: t) }
        appState = nil
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        try await super.tearDown()
    }

    // MARK: - Completion cards behind hidden requests

    /// "Auto-expand on question" off: the question waits behind its badge.
    /// A finished turn's card must still fold when its time is up.
    func testCompletionCardCollapsesWhileAHiddenQuestionWaits() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        try await ask("QX")
        XCTAssertEqual(appState.surface, .collapsed)
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "C1", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "C1"))

        await waitForSurface(.collapsed)
        XCTAssertEqual(appState.surface, .collapsed, "completion card should auto-collapse")
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "QX", "the question keeps its badge")
    }

    /// Same with "auto-expand on approval" off (#292).
    func testCompletionCardCollapsesWhileAHiddenApprovalWaits() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        try await requestApproval("PX")
        XCTAssertEqual(appState.surface, .collapsed)
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "C2", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "C2"))

        await waitForSurface(.collapsed)
        XCTAssertEqual(appState.surface, .collapsed, "completion card should auto-collapse")
    }

    /// Finished turns queued behind the first card are shown in turn, not
    /// dropped because a hidden request is waiting.
    func testQueuedCompletionsAreShownBehindAHiddenRequest() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        try await ask("QY")
        appState.completionAutoCollapseDelay = 0.3
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "first", "cwd": "/tmp"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "second", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "first"))

        await waitForSurface(.completionCard(sessionId: "second"))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "second"))
        await waitForSurface(.collapsed)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    /// A request arriving hidden while a completion card is up does not cut
    /// that card short by jumping to the next finished turn.
    func testHiddenRequestArrivingDoesNotCutACompletionCardShort() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        appState.completionAutoCollapseDelay = 30
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "shown", "cwd": "/tmp"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "queued", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "shown"))

        try await requestApproval("hidden")
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "shown"))
    }

    /// The session of the completion card on screen goes away while the
    /// pointer is on the card: nothing is left on it, so it folds.
    func testRemovedSessionsCompletionCardFoldsEvenUnderThePointer() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        appState.completionAutoCollapseDelay = 30
        try await ask("QZ")
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "gone", "cwd": "/tmp"]))
        XCTAssertEqual(appState.surface, .completionCard(sessionId: "gone"))
        appState.completionHasBeenEntered = true

        appState.removeSession("gone")
        XCTAssertEqual(appState.surface, .collapsed)
    }

    // MARK: - The card the user opened stays

    /// With "auto-expand on question" on, a non-head question card the user
    /// opened ("Answer" in the session list) must not be swapped for the head
    /// the next time the queue is re-evaluated.
    func testUserOpenedQuestionCardIsNotReplacedByTheHead() async throws {
        try await ask("QA")
        try await ask("QB")
        appState.openPendingQuestionCard(sessionId: "QB")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "QB"))
        appState.showNextPending()
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "QB"))
        XCTAssertEqual(appState.activeSessionId, "QB")

        // Answered, it gives way to the next one as usual.
        appState.skipQuestion(expectedSessionId: "QB")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "QA"))
    }

    /// A non-head approval card (reopened by a reminder, picked in the
    /// session list) stays too, and becomes the head so head-only mirrors
    /// act on what is on screen.
    func testOpenedNonHeadApprovalCardStaysAndBecomesTheHead() async throws {
        try await requestApproval("PA")
        try await requestApproval("PB")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PA"))
        appState.surface = .approvalCard(sessionId: "PB")

        appState.showNextPending()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PB"))
        XCTAssertEqual(appState.permissionQueue.first?.event.sessionId, "PB")

        appState.approvePermission(expectedSessionId: "PB")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PA"))
    }

    /// The card stays for the request it was opened for, not for whatever
    /// fills it next: once answered, the session's next question is weighed
    /// like a new one — here an OMP ask racing its own terminal dialog, which
    /// Smart Suppress folds.
    func testCardForAnAnsweredRequestIsReevaluated() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        appState.questionTerminalFrontmostDetector = { _ in true }
        try await ask("QS", agentId: nil, extra: ["_source": "pi", "_pi_tool_call_id": "blocking-1", "_term_app": "Ghostty"])
        try await ask("QS", agentId: "sub", extra: [
            "_source": "pi", "_pi_tool_call_id": "racing-2", "_term_app": "Ghostty",
            "_codeisland_native_ask_racing": true,
        ])
        XCTAssertEqual(appState.questionQueue.count, 2)
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "QS"))

        appState.skipQuestion(expectedSessionId: "QS")
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.surface, .collapsed, "the racing ask is Smart Suppressed, not kept on the old card")
    }

    // MARK: - Helpers

    /// Bounded: records a failure (and returns) if the surface never gets there.
    private func waitForSurface(_ expected: IslandSurface, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("surface never became \(expected)", file: file, line: line) {
            self.appState.surface == expected
        }
    }

    private func requestApproval(_ sid: String) async throws {
        let e = try event(["hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "Bash", "tool_input": ["command": "echo"]])
        pending.append(await startHookRequest { [appState] in appState!.handlePermissionRequest(e, continuation: $0) })
    }

    private func ask(_ sid: String, agentId: String? = nil, extra: [String: Any] = [:]) async throws {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]],
        ]
        if let agentId { payload["agent_id"] = agentId }
        payload.merge(extra) { _, new in new }
        let e = try event(payload)
        pending.append(await startHookRequest { [appState] in appState!.handleAskUserQuestion(e, continuation: $0) })
    }

    private func event(_ p: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: p)))
    }
}
