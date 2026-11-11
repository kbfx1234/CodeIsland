import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Follow-up reminders for display-only waits, end to end through AppState:
/// Claude Desktop Cowork approvals and questions, Cursor's in-IDE question,
/// AiWork prompts and a terminal permission prompt announced by a
/// Notification hook. None of them is queued, so a reminder re-chimes and
/// lights the hint but never opens a card. Clock, hold-back, terminal probes
/// and the sound sink are injected; `tick(now:)` is driven by hand.
@MainActor
final class DisplayOnlyWaitFollowUpTests: XCTestCase {
    typealias Key = FollowUpReminderScheduler.Key

    private var appState: AppState!
    private var followUps: FollowUpReminderController!
    private var now = Date(timeIntervalSinceReferenceDate: 90_000)
    private var interval: TimeInterval? = 60
    private var heldBack = false
    private var played: [String] = []
    private var fired: [FollowUpReminder] = []
    private var pending: [Task<Data, Never>] = []
    private var savedDefaults: [String: Any?] = [:]

    private let storeId = "local_7d3c2a10-display-only"
    private var coworkKey: String { AppState.coworkSessionKey(storeId) }
    private let cursorId = "4f1c8a2e-5b7d-4c11-9e2f-6a0b3c9d8e71"
    private let cursorBundleId = "com.todesktop.230313mzl4w4u92"

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
        // Auto-expand on: a queued request would get its card back, so a
        // display-only wait staying collapsed is the wait's own doing.
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)

        now = Date(timeIntervalSinceReferenceDate: 90_000)
        interval = 60
        heldBack = false
        played = []
        fired = []
        pending = []

        appState = AppState()
        appState.aiworkStateDirOverride = "/nonexistent/codeisland-tests/agentix"
        followUps = appState.followUps
        followUps.armsTimer = false
        followUps.clock = { [unowned self] in self.now }
        followUps.intervalProvider = { [unowned self] in self.interval }
        followUps.isHeldBack = { [unowned self] in self.heldBack }
        followUps.isPointerOverPanel = { false }
        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        followUps.playSound = { [unowned self] in self.played.append($0) }
        followUps.addReminderHandler { [unowned self] in self.fired.append($0) }
    }

    override func tearDown() async throws {
        for sid in Set(appState.permissionQueue.map { $0.event.sessionId ?? "default" }) {
            appState.handlePeerDisconnect(sessionId: sid)
        }
        for task in pending { _ = await task.value }
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

    // MARK: - Claude Desktop Cowork

    func testCoworkApprovalRemindsWithoutACardAndStopsOnceAnswered() async {
        var audit = coworkAudit(.permissionRequested(id: "r1", toolName: "Bash", detail: "rm -rf build"))
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))
        XCTAssertEqual(appState.sessions[coworkKey]?.status, .waitingApproval)
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertEqual(followUps.scheduler.origin(of: Key(.approval, coworkKey)), .displayOnly)
        XCTAssertEqual(followUps.armedWakeDate, now.addingTimeInterval(60))

        await advance(59)
        XCTAssertEqual(fired, [])
        await advance(1)
        XCTAssertEqual(fired.map(\.kind), [.approval])
        XCTAssertEqual(fired.first?.origin, .displayOnly)
        XCTAssertEqual(fired.first?.sessionId, coworkKey)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .collapsed, "nothing on the island can answer it")
        XCTAssertTrue(followUps.hintActive)
        XCTAssertEqual(followUps.hintPulse, 1)

        // Approved in Claude Desktop.
        audit.apply(.permissionResolved(id: "r1"))
        appState.applyCoworkUpdate(coworkUpdate(audit))
        XCTAssertEqual(appState.sessions[coworkKey]?.status, .processing)
        XCTAssertFalse(followUps.hintActive)
        XCTAssertNil(followUps.armedWakeDate)
        await advance(600)
        XCTAssertEqual(fired.count, 1)
    }

    func testCoworkQuestionRemindsAsAQuestionAndStopsOnceAnswered() async {
        var audit = coworkAudit(.permissionRequested(id: "q1", toolName: "AskUserQuestion", detail: "Which folder?"))
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))
        XCTAssertEqual(appState.sessions[coworkKey]?.status, .waitingQuestion)

        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.question])
        XCTAssertEqual(fired.first?.origin, .displayOnly)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertNil(appState.hiddenPendingQuestionSessionId, "no island question to badge")

        audit.apply(.assistantOutput(isSubagent: false, toolUse: nil))
        appState.applyCoworkUpdate(coworkUpdate(audit))
        XCTAssertNil(followUps.armedWakeDate)
        await advance(600)
        XCTAssertEqual(fired.count, 1)
    }

    func testCoworkWaitRemindsAtMostThreeTimes() async {
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        for _ in 0..<6 { await advance(60) }
        XCTAssertEqual(fired.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(fired.last?.isFinal, true)
        XCTAssertNil(followUps.armedWakeDate)
    }

    func testRepeatedUpdatesWhileWaitingDoNotRestartTheClock() async {
        let audit = coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls"))
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))
        await advance(40)
        appState.applyCoworkUpdate(coworkUpdate(audit))   // a title re-save
        await advance(20)
        XCTAssertEqual(fired.map(\.attempt), [1], "still due a minute after the wait began")
    }

    func testJumpingToACoworkWaitStopsItsReminders() async {
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        XCTAssertNotNil(followUps.armedWakeDate, "tracked before the cancel")
        NotificationCenter.default.post(
            name: .codeIslandDidJumpToSession, object: nil, userInfo: ["sessionId": coworkKey]
        )
        await advance(600)
        XCTAssertEqual(fired, [])
    }

    /// Jumped to (silenced), answered there, then a new card: that one is
    /// news and gets its own reminders.
    func testANewWaitAfterASilencedOneIsRemindedAgain() async {
        var audit = coworkAudit(.permissionRequested(id: "r1", toolName: "Bash", detail: "ls"))
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))
        NotificationCenter.default.post(
            name: .codeIslandDidJumpToSession, object: nil, userInfo: ["sessionId": coworkKey]
        )
        audit.apply(.permissionResolved(id: "r1"))
        audit.apply(.permissionRequested(id: "r2", toolName: "Bash", detail: "make"))
        // Both land in one batch: the session never visibly left the wait.
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))
        await advance(60)
        XCTAssertEqual(fired, [], "one continuous wait, silenced by the jump")

        audit.apply(.assistantOutput(isSubagent: false, toolUse: nil))
        appState.applyCoworkUpdate(coworkUpdate(audit))
        audit.apply(.permissionRequested(id: "r3", toolName: "Bash", detail: "make install"))
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))
        await advance(60)
        XCTAssertEqual(fired.map(\.sessionId), [coworkKey])
    }

    /// Smart Suppress's question, with Claude Desktop as the "terminal": in
    /// front means the user is looking at the card. Nothing happens on the
    /// Mac; remote channels still get it, marked as kept off the Mac.
    func testClaudeDesktopInFrontKeepsTheReminderOffTheMac() async {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        var probed: [String?] = []
        followUps.terminalFrontmost = { session in
            probed.append(session.termBundleId)
            return true
        }
        followUps.tabVisible = { _ in true }
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        await advance(60)
        XCTAssertEqual(fired.map(\.locallySuppressed), [true])
        XCTAssertEqual(played, [])
        XCTAssertFalse(followUps.hintActive)
        XCTAssertEqual(probed, [AppState.claudeDesktopBundleId])
    }

    func testLockedScreenDefersThenCatchesUp() async {
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        heldBack = true
        await advance(60)
        XCTAssertEqual(fired.map(\.delivery), [.deferred])
        XCTAssertEqual(fired.first?.origin, .displayOnly)
        XCTAssertEqual(played, [])

        heldBack = false
        await advance(30)
        XCTAssertEqual(fired.map(\.delivery), [.deferred, .catchUp])
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .collapsed)
    }

    func testArchivedCoworkTaskTakesItsWaitAlong() async {
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        appState.removeSession(coworkKey)
        XCTAssertNil(followUps.armedWakeDate)
        await advance(600)
        XCTAssertEqual(fired, [])
    }

    func testOffTracksNothing() async {
        interval = nil
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        XCTAssertTrue(followUps.scheduler.isEmpty)
        XCTAssertNil(followUps.armedWakeDate)
    }

    // MARK: - Cursor

    func testCursorQuestionRemindsUntilTheTranscriptMovesOn() async {
        startCursorSession()
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: cursorId, lastUserPrompt: nil, lastAssistantMessage: nil,
            cursorQuestion: .pending(prompt: "Which DB?")
        ))
        XCTAssertEqual(appState.sessions[cursorId]?.status, .waitingQuestion)
        XCTAssertEqual(followUps.scheduler.origin(of: Key(.question, cursorId)), .displayOnly)

        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.question])
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertTrue(followUps.hintActive)

        // Answered inside Cursor.
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: cursorId, lastUserPrompt: "PostgreSQL", lastAssistantMessage: nil,
            cursorQuestion: .cleared
        ))
        XCTAssertFalse(followUps.hintActive)
        XCTAssertNil(followUps.armedWakeDate)
        await advance(600)
        XCTAssertEqual(fired.count, 1)
    }

    func testCursorQuestionEndedByAHookIsNotReminded() async throws {
        startCursorSession()
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: cursorId, lastUserPrompt: nil, lastAssistantMessage: nil,
            cursorQuestion: .pending(prompt: "Which DB?")
        ))
        appState.handleEvent(try event([
            "hook_event_name": "Stop", "session_id": cursorId, "_source": "cursor",
        ]))
        XCTAssertNotEqual(appState.sessions[cursorId]?.status, .waitingQuestion)
        await advance(60)
        XCTAssertFalse(fired.contains { $0.kind == .question })
    }

    // MARK: - AiWork

    func testAiWorkApprovalRemindsUntilResolved() async {
        aiworkEvent("stream.approval_required", data: #""tool_name":"shell","command":"git push --force""#)
        let key = AppState.aiworkSessionPrefix + "acp:coder:dow"
        XCTAssertEqual(appState.sessions[key]?.status, .waitingApproval)
        XCTAssertEqual(followUps.scheduler.origin(of: Key(.approval, key)), .displayOnly)

        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.approval])
        XCTAssertEqual(fired.first?.sessionId, key)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .collapsed)

        aiworkEvent("stream.approval_resolved", data: #""decision":"approve""#)
        XCTAssertNil(followUps.armedWakeDate)
        await advance(600)
        XCTAssertEqual(fired.count, 1)
    }

    func testAiWorkQuestionIsAQuestion() async {
        aiworkEvent("stream.question_required", data: #""message":"Deploy now?""#)
        await advance(60)
        XCTAssertEqual(fired.map(\.kind), [.question])
        aiworkEvent("stream.question_resolved", data: #""answer":"yes""#)
        XCTAssertNil(followUps.armedWakeDate)
    }

    // MARK: - Terminal permission prompt (Notification hook)

    func testTerminalPermissionPromptRemindsUntilTheNextActivity() async throws {
        appState.handleEvent(try event([
            "hook_event_name": "Notification", "session_id": "term",
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash",
        ]))
        XCTAssertEqual(appState.sessions["term"]?.status, .waitingApproval)
        XCTAssertEqual(followUps.scheduler.origin(of: Key(.approval, "term")), .displayOnly)

        await advance(60)
        XCTAssertEqual(fired.map(\.origin), [.displayOnly])
        XCTAssertEqual(appState.surface, .collapsed)

        // Approved in the terminal: the tool runs.
        appState.handleEvent(try event([
            "hook_event_name": "PostToolUse", "session_id": "term", "tool_name": "Bash",
        ]))
        XCTAssertNil(followUps.armedWakeDate)
        await advance(600)
        XCTAssertEqual(fired.count, 1)
    }

    /// The prompt's own PermissionRequest reaching the island: the same wait
    /// changes hands, keeps its clock, and its reminder reopens the card.
    func testQueuedRequestAdoptsTheTerminalPromptsWait() async throws {
        appState.handleEvent(try event([
            "hook_event_name": "Notification", "session_id": "term",
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash",
        ]))
        await advance(30)
        try await requestApproval("term")
        XCTAssertEqual(followUps.scheduler.origin(of: Key(.approval, "term")), .island)
        appState.surface = .collapsed

        await advance(30)
        XCTAssertEqual(fired.map(\.origin), [.island])
        XCTAssertEqual(fired.first?.waitingSince, now.addingTimeInterval(-60))
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "term"))

        appState.approvePermission(expectedSessionId: "term")
        XCTAssertNil(followUps.armedWakeDate, "answered on the island — the prompt's status does not linger as a wait")
    }

    // MARK: - Helpers

    private func advance(_ seconds: TimeInterval) async {
        now = now.addingTimeInterval(seconds)
        await followUps.tick(now: now)
    }

    private func coworkAudit(_ events: CoworkAuditEvent...) -> CoworkAuditState {
        var audit = CoworkAuditState()
        audit.apply(.userPrompt(text: "tidy the repo", isSynthetic: false))
        audit.apply(events)
        return audit
    }

    private func coworkUpdate(
        _ audit: CoworkAuditState,
        permissionsRequested: Int = 0
    ) -> CoworkSessionWatcher.SessionUpdate {
        let metadata = CoworkSessionMetadata(
            sessionId: storeId,
            cliSessionId: "cli-display-only",
            title: "Tidy the repo",
            cwd: "/sessions/quiet-brave-otter",
            userSelectedFolders: ["/Users/alice/code/app"],
            model: "claude-opus-4-5-20251101",
            createdAt: Date(timeIntervalSinceNow: -3600),
            lastActivityAt: Date(timeIntervalSinceNow: -60),
            isArchived: false,
            sessionType: nil
        )
        return CoworkSessionWatcher.SessionUpdate(
            sessionId: storeId,
            metadata: metadata,
            audit: audit,
            transcriptPath: nil,
            lastActivity: nil,
            isLive: true,
            promptsStarted: 0,
            turnsCompleted: 0,
            permissionsRequested: permissionsRequested
        )
    }

    private func startCursorSession() {
        let path = "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorId)/\(cursorId).jsonl"
        var session = SessionSnapshot()
        session.source = "cursor"
        session.status = .processing
        session.transcriptPath = path
        session.termBundleId = cursorBundleId
        appState.sessions[cursorId] = session
        appState.attachedTranscriptPaths[cursorId] = path
    }

    private func aiworkEvent(_ name: String, data: String) {
        let json = #"{"kind":"event","category":"session","operation":"sessions.watch","event":{"name":""#
            + name
            + #""},"data":{"#
            + data
            + #","session":{"session_id":"acp:coder:dow","cwd":"/tmp/proj","title":"Ship","client_type":"AiWorkGUI"}},"meta":{"session_id":"acp:coder:dow"}}"#
        guard let frame = AiWorkWatchClient.parseFrame(Data(json.utf8)) else {
            return XCTFail("unparseable frame: \(json)")
        }
        appState.handleAiWorkStreamEvent(name: name, frame: frame, agentId: "coder")
    }

    private func requestApproval(_ sessionId: String) async throws {
        let request = try event([
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": ["command": "echo hi"],
        ])
        pending.append(Task<Data, Never> { [appState] in
            await withCheckedContinuation { appState!.handlePermissionRequest(request, continuation: $0) }
        })
        // Queued before going on, so tearDown can always resume it.
        for _ in 0..<100 where !appState.permissionQueue.contains(where: { $0.event.sessionId == sessionId }) {
            await Task.yield()
        }
        XCTAssertTrue(appState.permissionQueue.contains { $0.event.sessionId == sessionId })
    }

    private func event(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
