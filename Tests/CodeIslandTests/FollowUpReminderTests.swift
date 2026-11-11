import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Follow-up reminders end to end through AppState: what gets re-announced,
/// when it stops, and what it does to the island. The clock, the hold-back
/// state, the terminal probes and the sound sink are injected; the wake-up
/// timer is off and `tick(now:)` is driven by hand.
@MainActor
final class FollowUpReminderTests: XCTestCase {
    private var appState: AppState!
    private var followUps: FollowUpReminderController!
    private var now = Date(timeIntervalSinceReferenceDate: 50_000)
    private var interval: TimeInterval? = 60
    private var heldBack = false
    private var pointerOverPanel = false
    private var played: [String] = []
    private var fired: [FollowUpReminder] = []
    /// Reminders the island kept to itself (`locallySuppressed`), which only
    /// remote channels hear about.
    private var keptOffTheMac: [FollowUpReminder] = []
    private var pending: [Task<Data, Never>] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.autoExpandOnPermission,
        SettingsKey.autoExpandOnQuestion,
        SettingsKey.smartSuppress,
        SettingsKey.completionNotificationStyle,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        // Glance keeps completions off the card path, so tests see only what
        // the reminders themselves do to the surface.
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)

        now = Date(timeIntervalSinceReferenceDate: 50_000)
        interval = 60
        heldBack = false
        pointerOverPanel = false
        played = []
        fired = []
        keptOffTheMac = []
        pending = []

        appState = AppState()
        followUps = appState.followUps
        followUps.armsTimer = false
        followUps.clock = { [unowned self] in self.now }
        followUps.intervalProvider = { [unowned self] in self.interval }
        followUps.isHeldBack = { [unowned self] in self.heldBack }
        followUps.isPointerOverPanel = { [unowned self] in self.pointerOverPanel }
        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        followUps.playSound = { [unowned self] in self.played.append($0) }
        followUps.addReminderHandler { [unowned self] reminder in
            if reminder.locallySuppressed {
                self.keptOffTheMac.append(reminder)
            } else {
                self.fired.append(reminder)
            }
        }
    }

    override func tearDown() async throws {
        for sid in Set(appState.permissionQueue.map { $0.event.sessionId ?? "default" }
            + appState.questionQueue.map { $0.event.sessionId ?? "default" }) {
            appState.handlePeerDisconnect(sessionId: sid)
        }
        // `try?`: a stuck request is already recorded as a failure; the rest of
        // the teardown must still run so the defaults are restored.
        for task in pending { _ = try? await awaitValue(of: task) }
        followUps = nil
        appState = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        try await super.tearDown()
    }

    // MARK: - Off

    func testOffCostsNothing() async throws {
        interval = nil
        try await requestApproval("off-a")
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "off-c"]))

        XCTAssertTrue(followUps.scheduler.isEmpty)
        XCTAssertNil(followUps.armedWakeDate)
        await advance(3_600)
        XCTAssertEqual(fired, [])
        XCTAssertEqual(played, [])
    }

    func testTurningOffDropsTrackedItemsAndTheWakeUp() async throws {
        try await requestApproval("switch-off")
        XCTAssertNotNil(followUps.armedWakeDate)

        interval = nil
        followUps.settingsChanged()
        XCTAssertTrue(followUps.scheduler.isEmpty)
        XCTAssertNil(followUps.armedWakeDate)
    }

    func testIntervalChoicesMapToMinutes() {
        XCTAssertNil(FollowUpReminderController.interval(forMinutes: 0))
        XCTAssertEqual(FollowUpReminderController.interval(forMinutes: 3), 180)
        XCTAssertEqual(FollowUpReminderController.intervalChoices, [0, 1, 2, 3, 5])
    }

    // MARK: - Approvals

    func testWaitingApprovalRemindsAndReopensItsCard() async throws {
        try await requestApproval("appr")
        XCTAssertEqual(followUps.armedWakeDate, now.addingTimeInterval(60))
        appState.surface = .collapsed   // the user closed it and walked off

        await advance(59)
        XCTAssertEqual(fired, [])
        await advance(1)
        XCTAssertEqual(fired.map(\.kind), [.approval])
        XCTAssertEqual(fired.first?.sessionId, "appr")
        XCTAssertEqual(fired.first?.delivery, .onTime)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "appr"))
    }

    func testApprovalRemindsAtMostThreeTimes() async throws {
        try await requestApproval("three")
        for _ in 0..<6 { await advance(60) }
        XCTAssertEqual(fired.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(fired.last?.isFinal, true)
        XCTAssertNil(followUps.armedWakeDate, "nothing left to wake up for")
    }

    func testAnsweredApprovalIsNotReminded() async throws {
        try await requestApproval("answered")
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        appState.approvePermission(expectedSessionId: "answered")
        XCTAssertNil(followUps.armedWakeDate)
        await advance(600)
        XCTAssertEqual(fired, [])
    }

    func testDeniedApprovalIsNotReminded() async throws {
        try await requestApproval("denied")
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        appState.denyPermission(expectedSessionId: "denied")
        await advance(600)
        XCTAssertEqual(fired, [])
    }

    func testDismissedApprovalIsNotReminded() async throws {
        try await requestApproval("dismissed")
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        appState.dismissPermissionPrompt(expectedSessionId: "dismissed")
        await advance(600)
        XCTAssertEqual(fired, [], "dismissing hides the prompt on purpose")
    }

    func testJumpingToTheSessionStopsItsReminders() async throws {
        try await requestApproval("jumped")
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        NotificationCenter.default.post(
            name: .codeIslandDidJumpToSession, object: nil, userInfo: ["sessionId": "jumped"]
        )
        await advance(600)
        XCTAssertEqual(fired, [])
    }

    func testAutoExpandOffOnlyChimesAndHints() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        try await requestApproval("quiet-card")
        XCTAssertEqual(appState.surface, .collapsed)

        await advance(60)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .collapsed, "the card must not open by itself")
        XCTAssertTrue(followUps.hintActive)
        XCTAssertEqual(followUps.hintPulse, 1)

        // Answered in the terminal: the hint goes out on its own.
        appState.handlePeerDisconnect(sessionId: "quiet-card")
        XCTAssertFalse(followUps.hintActive)
    }

    func testOpeningTheIslandClearsTheHint() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        try await requestApproval("hint-open")
        await advance(60)
        XCTAssertTrue(followUps.hintActive)
        appState.surface = .sessionList
        XCTAssertFalse(followUps.hintActive)
    }

    /// The card under the pointer is not reminded about while it is being
    /// read — but reading it once is not answering it: the reminder comes
    /// back an interval later, with no attempt spent.
    func testCardUnderThePointerPostponesItsReminder() async throws {
        try await requestApproval("looking")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "looking"))
        pointerOverPanel = true
        followUps.pointerOverIsland = true

        await advance(60)
        XCTAssertEqual(fired, [])
        XCTAssertEqual(played, [])
        XCTAssertEqual(keptOffTheMac.map(\.sessionId), ["looking"])
        XCTAssertEqual(followUps.armedWakeDate, now.addingTimeInterval(60), "postponed, not silenced")
        pointerOverPanel = false
        followUps.pointerOverIsland = false
        await advance(60)
        XCTAssertEqual(fired.map(\.attempt), [1], "the skipped reminder was not counted")
        XCTAssertEqual(played, ["PermissionRequest"])
    }

    /// The panel's window is a fixed, mostly transparent canvas around the
    /// island. A pointer resting in it — below the notch, beside the card —
    /// is not on the card, and does not make anyone a reader of it.
    func testPointerInTheWindowButOffTheIslandStillReminds() async throws {
        try await requestApproval("beside")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "beside"))
        pointerOverPanel = true
        followUps.pointerOverIsland = false

        await advance(60)
        XCTAssertEqual(fired.map(\.sessionId), ["beside"])
        XCTAssertEqual(played, ["PermissionRequest"])
    }

    /// Same with the session list open: only a pointer on the list itself
    /// reads as looking at everything in it.
    func testSessionListOpenWithThePointerElsewhereStillReminds() async throws {
        try await requestApproval("list-open")
        appState.surface = .sessionList
        pointerOverPanel = true

        await advance(60)
        XCTAssertEqual(fired.map(\.sessionId), ["list-open"])

        followUps.pointerOverIsland = true
        await advance(60)
        XCTAssertEqual(fired.count, 1, "on the list: the next one waits")
        XCTAssertEqual(keptOffTheMac.map(\.attempt), [2])
    }

    /// A hover flag left behind by a view that went away mid-hover does not
    /// count once the pointer is outside the window.
    func testStaleIslandHoverOutsideTheWindowDoesNotCount() async throws {
        try await requestApproval("stale-hover")
        followUps.pointerOverIsland = true
        pointerOverPanel = false

        await advance(60)
        XCTAssertEqual(fired.map(\.sessionId), ["stale-hover"])
    }

    /// An auto-opened card with nobody in front of it is exactly who the
    /// reminder is for: it chimes, and the card simply stays up.
    func testOpenCardNobodyIsLookingAtStillChimes() async throws {
        try await requestApproval("unattended")
        await advance(60)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "unattended"))
    }

    func testSessionTabInFrontPostpones() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        followUps.terminalFrontmost = { _ in true }
        followUps.tabVisible = { _ in true }
        try await requestApproval("in-front", termApp: "iTerm.app")
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")

        await advance(60)
        XCTAssertEqual(fired, [])
        XCTAssertEqual(played, [])
        XCTAssertEqual(keptOffTheMac.map(\.attempt), [1])

        // The terminal happened to be in front at that moment; the user then
        // moved on to something else and the request is still waiting.
        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        appState.surface = .collapsed
        await advance(60)
        XCTAssertEqual(fired.map(\.attempt), [1])
        XCTAssertEqual(played, ["PermissionRequest"])
    }

    /// A finished turn has a single reminder; the terminal being in front at
    /// its due time must not use it up.
    func testCompletionWithItsTabInFrontIsPostponedNotDropped() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        followUps.terminalFrontmost = { _ in true }
        followUps.tabVisible = { _ in true }
        appState.handleEvent(try event([
            "hook_event_name": "Stop", "session_id": "front-done", "_term_app": "iTerm.app",
        ]))
        await advance(60)
        XCTAssertEqual(fired, [])

        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.completion])
        XCTAssertEqual(played, ["Stop"])
        await advance(600)
        XCTAssertEqual(fired.count, 1, "still only one reminder for a finished turn")
    }

    func testOtherTabOfTheSameTerminalStillReminds() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        followUps.terminalFrontmost = { _ in true }
        followUps.tabVisible = { _ in false }
        try await requestApproval("other-tab", termApp: "iTerm.app")
        appState.surface = .collapsed

        await advance(60)
        XCTAssertEqual(fired.map(\.sessionId), ["other-tab"])
    }

    /// `showNextPending` moves the next visible request to the head. Done as a
    /// remove + insert, the queue briefly lacked it and its reminder started
    /// over (silenced or not).
    func testPromotingTheNextRequestKeepsItsReminderClock() async throws {
        try await requestApproval("first")
        await advance(30)
        try await requestApproval("second")
        await advance(15)
        appState.approvePermission(expectedSessionId: "first")   // "second" moves to the head
        appState.surface = .collapsed

        await advance(45)
        XCTAssertEqual(fired.map(\.sessionId), ["second"], "due a minute after it was queued")
    }

    // MARK: - Held back

    func testLockedScreenDefersThenCatchesUpRightAfterUnlock() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        // The terminal is still the front app behind the lock screen; that
        // must not swallow the catch-up.
        followUps.terminalFrontmost = { _ in true }
        followUps.tabVisible = { _ in true }
        try await requestApproval("locked", termApp: "iTerm.app")
        heldBack = true

        await advance(60)
        XCTAssertEqual(fired.map(\.delivery), [.deferred], "remote channels still hear about it")
        XCTAssertEqual(played, [])
        await advance(120)
        XCTAssertEqual(fired.count, 1, "reported once while locked")

        heldBack = false
        await advance(30)   // unlocked 3.5 minutes in
        XCTAssertEqual(fired.map(\.delivery), [.deferred, .catchUp])
        XCTAssertEqual(fired.last?.attempt, 1)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(followUps.armedWakeDate, now.addingTimeInterval(60))
    }

    func testResolvedWhileLockedNeedsNoCatchUp() async throws {
        try await requestApproval("resolved-locked")
        heldBack = true
        await advance(60)
        appState.approvePermission(expectedSessionId: "resolved-locked")
        heldBack = false
        await advance(30)
        XCTAssertEqual(fired.map(\.delivery), [.deferred])
        XCTAssertEqual(played, [])
    }

    func testOwedItemKeepsAOneMinuteRecheckForQuietHoursEnding() async throws {
        try await requestApproval("owed")
        heldBack = true
        await advance(60)
        XCTAssertEqual(followUps.armedWakeDate, now.addingTimeInterval(60))
    }

    // MARK: - Questions

    func testWaitingQuestionReopensItsCard() async throws {
        let event = try event([
            "hook_event_name": "PermissionRequest",
            "session_id": "ask",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]],
        ])
        pending.append(await startHookRequest { [appState] in appState!.handleAskUserQuestion(event, continuation: $0) })
        XCTAssertEqual(appState.questionQueue.count, 1)
        appState.surface = .collapsed

        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.question])
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "ask"))
        XCTAssertEqual(played, ["PermissionRequest"])
    }

    /// "Auto-expand on question" off: the reminder chimes and hints like an
    /// approval with its switch off, and the question keeps its click-to-open
    /// badge instead of the card popping open.
    func testQuestionAutoExpandOffOnlyChimesAndHints() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        let event = try event([
            "hook_event_name": "PermissionRequest",
            "session_id": "quiet-ask",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]],
        ])
        pending.append(await startHookRequest { [appState] in appState!.handleAskUserQuestion(event, continuation: $0) })
        XCTAssertEqual(appState.surface, .collapsed)

        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.question])
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .collapsed, "the card must not open by itself")
        XCTAssertTrue(followUps.hintActive)
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "quiet-ask")
    }

    // MARK: - Completions

    func testUnseenCompletionRemindsOnce() async throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "done"]))
        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.completion])
        XCTAssertEqual(played, ["Stop"])
        XCTAssertTrue(followUps.hintActive)

        await advance(600)
        XCTAssertEqual(fired.count, 1)
    }

    /// A turn that died on an API error is followed up as the error it was:
    /// the error jingle, not the "done" one.
    func testFailedTurnIsFollowedUpWithTheErrorSound() async throws {
        appState.handleEvent(try event([
            "hook_event_name": "StopFailure", "session_id": "died",
            "error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached",
        ]))
        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.completion])
        XCTAssertEqual(fired.map(\.turnFailed), [true])
        XCTAssertEqual(played, [EventSoundRouting.turnFailed])

        // The next turn finishes normally: back to the regular sound.
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "died", "prompt": "retry"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "died", "last_assistant_message": "Done."]))
        await advance(60)
        XCTAssertEqual(fired.map(\.turnFailed), [true, false])
        XCTAssertEqual(played, [EventSoundRouting.turnFailed, "Stop"])
    }

    func testNewActivityCancelsTheCompletionReminder() async throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "busy"]))
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "busy", "prompt": "next"]))
        await advance(60)
        XCTAssertEqual(fired, [])
    }

    func testOpeningTheSessionListCountsAsSeen() async throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "seen"]))
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        appState.surface = .sessionList
        appState.surface = .collapsed
        await advance(60)
        XCTAssertEqual(fired, [])
    }

    func testHoveringTheCompletionCardCountsAsSeen() async throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "hovered"]))
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        appState.surface = .completionCard(sessionId: "hovered")
        appState.completionHasBeenEntered = true
        appState.surface = .collapsed
        await advance(60)
        XCTAssertEqual(fired, [])
    }

    func testCompletionsAreNotChasedWhenTheirNotificationIsOff() throws {
        UserDefaults.standard.set("off", forKey: SettingsKey.completionNotificationStyle)
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "muted-style"]))
        XCTAssertTrue(followUps.scheduler.isEmpty)
    }

    func testInterruptedTurnIsNotChased() throws {
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "esc", "stop_reason": "user"]))
        XCTAssertTrue(followUps.scheduler.isEmpty)
    }

    /// The user stopped an AiWork stream: its card still pops, but like an
    /// Esc'd hook turn it is not chased — it used to be followed up as
    /// "finished". A completed stream still is.
    func testAbortedAiWorkStreamIsNotChased() throws {
        // Hydrate falls back to daemon discovery: keep it off any real daemon.
        appState.aiworkStateDirOverride = "/nonexistent/codeisland-tests/agentix"
        func stream(_ name: String, _ daemonSessionId: String) throws {
            let frame = try XCTUnwrap(AiWorkWatchClient.parseFrame(Data("""
            {"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"\(name)"},"data":{"session":{"session_id":"\(daemonSessionId)","cwd":"/tmp/proj"}},"meta":{"session_id":"\(daemonSessionId)"}}
            """.utf8)))
            appState.handleAiWorkStreamEvent(name: name, frame: frame, agentId: "coder")
        }

        try stream("stream.started", "acp:coder:stopped")
        try stream("stream.aborted", "acp:coder:stopped")
        XCTAssertEqual(appState.sessions["aiwork:acp:coder:stopped"]?.status, .idle)
        XCTAssertTrue(appState.glanceCompletionActive, "its completion is still announced")
        XCTAssertTrue(followUps.scheduler.isEmpty)

        try stream("stream.started", "acp:coder:done")
        try stream("stream.completed", "acp:coder:done")
        XCTAssertEqual(followUps.scheduler.trackedKeys, [FollowUpReminderScheduler.Key(.completion, "aiwork:acp:coder:done")])
    }

    /// Several items due in one tick: one card, one chime per kind.
    func testOneTickOneCardOneChimePerKind() async throws {
        try await requestApproval("burst-1")
        try await requestApproval("burst-2")
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "burst-done"]))
        appState.surface = .collapsed

        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.approval, .approval, .completion])
        XCTAssertEqual(played, ["PermissionRequest", "Stop"])
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "burst-1"))
        XCTAssertTrue(followUps.hintActive, "the others still light the hint for later")
    }

    // MARK: - Helpers

    private func advance(_ seconds: TimeInterval) async {
        now = now.addingTimeInterval(seconds)
        await followUps.tick(now: now)
    }

    private func requestApproval(_ sessionId: String, termApp: String? = nil) async throws {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": ["command": "echo hi"],
        ]
        if let termApp { payload["_term_app"] = termApp }
        let request = try event(payload)
        pending.append(await startHookRequest { [appState] in appState!.handlePermissionRequest(request, continuation: $0) })
        XCTAssertTrue(appState.permissionQueue.contains { $0.event.sessionId == sessionId })
    }

    private func event(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
