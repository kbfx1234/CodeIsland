import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Records requests instead of sending them: nothing here reaches a real
/// push service.
private final class DisplayOnlyRecordingTransport: PushTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PushHTTPRequest] = []

    var requests: [PushHTTPRequest] { lock.withLock { recorded } }

    func send(_ request: PushHTTPRequest) async -> PushTransportResponse {
        lock.withLock { recorded.append(request) }
        return PushTransportResponse(statusCode: 200, body: Data(#"{"code":200,"message":"success"}"#.utf8))
    }
}

/// Pushes for display-only waits, from AppState to the request a Bark channel
/// would send: one push when the wait begins — with what is asked and where to
/// answer it — none for updates while it continues, and the follow-up
/// reminder's own push.
@MainActor
final class DisplayOnlyWaitPushTests: XCTestCase {
    private var transport = DisplayOnlyRecordingTransport()
    /// Push settings live in a private suite, never in `.standard`.
    private let suiteName = "DisplayOnlyWaitPushTests"
    private var defaults: UserDefaults!
    private var savedSmartSuppress: Any?
    private var presence = PushPresenceSnapshot(screenLocked: true)

    private let storeId = "local_9a8b7c6d-display-only-push"
    private var coworkKey: String { AppState.coworkSessionKey(storeId) }
    private let cursorId = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)

        transport = DisplayOnlyRecordingTransport()
        presence = PushPresenceSnapshot(screenLocked: true)
        let notifier = PushNotifier.shared
        notifier.resetForTesting()
        notifier.defaults = defaults
        notifier.transport = transport
        notifier.presence = { [unowned self] in self.presence }
        notifier.armsCatchUpTimer = false
        defaults.set(true, forKey: SettingsKey.pushEnabled)
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "TESTKEY"
        bark.events = PushEventKind.defaultSelection
        defaults.set(PushChannelConfig.encodeList([bark]), forKey: SettingsKey.pushChannels)
    }

    override func tearDown() {
        let notifier = PushNotifier.shared
        notifier.transport = URLSessionPushTransport.shared
        notifier.presence = { PushPresence.current() }
        notifier.armsCatchUpTimer = true
        notifier.clock = Date.init
        notifier.defaults = .standard
        notifier.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        if let savedSmartSuppress {
            UserDefaults.standard.set(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress)
        }
        super.tearDown()
    }

    // MARK: - Claude Desktop Cowork

    func testCoworkApprovalPushesOnceWithTheCommandAndWhereToApprove() async throws {
        let appState = makeAppState()
        let audit = coworkAudit(.permissionRequested(id: "r1", toolName: "Bash", detail: "rm -rf build"))
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))

        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["title"] as? String, "🔐 Claude · app")
        XCTAssertEqual(body["subtitle"] as? String, "\(L10n.shared["push_msg_permission"]): Bash")
        XCTAssertEqual(body["body"] as? String, "rm -rf build\n\(answerIn("Claude Desktop"))")
        XCTAssertEqual(body["level"] as? String, "timeSensitive")

        // Updates while the same card waits push nothing — not even something
        // for the dedupe to swallow.
        PushNotifier.shared.resetForTesting()
        appState.applyCoworkUpdate(coworkUpdate(audit))
        appState.applyCoworkUpdate(coworkUpdate(audit, permissionsRequested: 1))
        XCTAssertNil(PushNotifier.shared.lastDecision)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCoworkQuestionPushesTheQuestion() async throws {
        let appState = makeAppState()
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "q1", toolName: "AskUserQuestion", detail: "Which folder?")),
            permissionsRequested: 1
        ))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["title"] as? String, "❓ Claude · app")
        XCTAssertEqual(body["subtitle"] as? String, L10n.shared["push_msg_question"])
        XCTAssertEqual(body["body"] as? String, "Which folder?\n\(answerIn("Claude Desktop"))")

        PushNotifier.shared.resetForTesting()
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "q1", toolName: "AskUserQuestion", detail: "Which folder?"))
        ))
        XCTAssertNil(PushNotifier.shared.lastDecision)
    }

    /// A card rebuilt at launch was already waiting before CodeIsland saw it:
    /// no "new approval" push, only reminders.
    func testCoworkWaitFoundAtLaunchIsNotPushed() {
        let appState = makeAppState()
        appState.applyCoworkUpdate(
            coworkUpdate(coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), isLive: false),
            isLaunch: true
        )
        XCTAssertEqual(appState.sessions[coworkKey]?.status, .waitingApproval)
        XCTAssertNil(PushNotifier.shared.lastDecision)
    }

    func testNothingIsPushedWhileThePersonIsAtTheMac() {
        presence = PushPresenceSnapshot(idleSeconds: 2)
        let appState = makeAppState()
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.userPresent))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// Skipped while present, pushed once the screen locks — still waiting.
    func testWaitHeldBackWhilePresentIsPushedWhenTheScreenLocks() async throws {
        presence = PushPresenceSnapshot(idleSeconds: 2)
        let appState = makeAppState()
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        XCTAssertTrue(PushNotifier.shared.hasHeldBackRequests)

        presence = PushPresenceSnapshot(screenLocked: true)
        PushNotifier.shared.userLeft()
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        XCTAssertEqual(sentBodies().first?["body"] as? String, "ls\n\(answerIn("Claude Desktop"))")
    }

    func testChannelWithoutApprovalsSkipsIt() {
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "TESTKEY"
        bark.events = [.completion]
        defaults.set(PushChannelConfig.encodeList([bark]), forKey: SettingsKey.pushChannels)
        let appState = makeAppState()
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "ls")), permissionsRequested: 1
        ))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.noChannel))
    }

    // MARK: - Cursor

    func testCursorQuestionPushesOncePerQuestion() async throws {
        let appState = makeAppState()
        startCursorSession(appState)
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: cursorId, lastUserPrompt: nil, lastAssistantMessage: nil,
            cursorQuestion: .pending(prompt: "Which DB?")
        ))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["title"] as? String, "❓ Cursor")
        XCTAssertEqual(body["subtitle"] as? String, L10n.shared["push_msg_question"])
        XCTAssertEqual(body["body"] as? String, "Which DB?\n\(answerIn("Cursor"))")

        // The tail re-reads the same trailing question.
        PushNotifier.shared.resetForTesting()
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: cursorId, lastUserPrompt: nil, lastAssistantMessage: "still waiting",
            cursorQuestion: .pending(prompt: "Which DB?")
        ))
        XCTAssertNil(PushNotifier.shared.lastDecision)

        // Answered, then a new question: that one is news.
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: cursorId, lastUserPrompt: "Postgres", lastAssistantMessage: nil, cursorQuestion: .cleared
        ))
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: cursorId, lastUserPrompt: nil, lastAssistantMessage: nil,
            cursorQuestion: .pending(prompt: "Which schema?")
        ))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(2)
        XCTAssertEqual(sentBodies().last?["body"] as? String, "Which schema?\n\(answerIn("Cursor"))")
    }

    // MARK: - AiWork

    func testAiWorkApprovalPushesOnceWithToolAndCommand() async throws {
        let appState = makeAppState()
        aiworkEvent(appState, "stream.approval_required", data: #""tool_name":"shell","command":"git push --force""#)
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["title"] as? String, "🔐 AiWork · proj")
        XCTAssertEqual(body["subtitle"] as? String, "\(L10n.shared["push_msg_permission"]): shell")
        XCTAssertEqual(body["body"] as? String, "git push --force\n\(answerIn("AiWork"))")

        // A replayed event and a metadata change while the same approval waits.
        PushNotifier.shared.resetForTesting()
        aiworkEvent(appState, "stream.approval_required", data: #""tool_name":"shell","command":"git push --force""#)
        aiworkEvent(appState, "stream.session_info_changed", data: #""phase":"info""#)
        XCTAssertNil(PushNotifier.shared.lastDecision)
    }

    func testAiWorkQuestionPushesTheMessage() async throws {
        let appState = makeAppState()
        aiworkEvent(appState, "stream.question_required", data: #""message":"Deploy now?""#)
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["subtitle"] as? String, L10n.shared["push_msg_question"])
        XCTAssertEqual(body["body"] as? String, "Deploy now?\n\(answerIn("AiWork"))")
    }

    // MARK: - Terminal permission prompt

    /// A `permission_prompt` Notification can arrive a beat before the
    /// island queues the same request; pushing it would spend the approval's
    /// dedupe slot on a poorer message. It is only reminded.
    func testTerminalPermissionPromptIsNotPushedOnArrival() throws {
        let appState = makeAppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Notification", "session_id": "push-term", "_term_app": "iTerm.app",
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash",
        ]))
        XCTAssertEqual(appState.sessions["push-term"]?.status, .waitingApproval)
        XCTAssertNil(PushNotifier.shared.lastDecision)
    }

    // MARK: - Follow-up reminders

    private var followUpNow = Date(timeIntervalSinceReferenceDate: 120_000)

    func testDeferredReminderForACoworkWaitIsPushed() async throws {
        let appState = makeAppState()
        let followUps = startFollowUps(appState)
        appState.applyCoworkUpdate(coworkUpdate(
            coworkAudit(.permissionRequested(id: "r", toolName: "Bash", detail: "make deploy")),
            permissionsRequested: 1
        ))
        await waitForRequests(1)

        followUpNow = followUpNow.addingTimeInterval(61)
        await followUps.tick(now: followUpNow)
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(2)
        let reminder = try XCTUnwrap(sentBodies().last)
        XCTAssertEqual(reminder["title"] as? String, "⏰ Claude · app")
        XCTAssertEqual(
            reminder["subtitle"] as? String,
            "\(L10n.shared["push_msg_reminder"]) · \(String(format: L10n.shared["push_msg_waiting_minutes"], 1))"
        )
        XCTAssertEqual(
            reminder["body"] as? String,
            "\(L10n.shared["push_msg_permission"]): Bash\nmake deploy\n\(answerIn("Claude Desktop"))"
        )
        XCTAssertEqual(reminder["level"] as? String, "timeSensitive")
    }

    func testDeferredReminderForATerminalPromptCarriesItsText() async throws {
        let appState = makeAppState()
        let followUps = startFollowUps(appState)
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Notification", "session_id": "push-term-remind", "_term_app": "iTerm.app",
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash",
        ]))

        followUpNow = followUpNow.addingTimeInterval(61)
        await followUps.tick(now: followUpNow)
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        XCTAssertEqual(
            sentBodies().last?["body"] as? String,
            "\(L10n.shared["push_msg_permission"])\nClaude needs your permission to use Bash\n\(answerIn("iTerm2"))"
        )
    }

    func testReminderForAWaitThatEndedIsNotPushed() {
        let appState = makeAppState()
        startCursorSession(appState)
        let reminder = FollowUpReminder(
            kind: .question, sessionId: cursorId, attempt: 1, maxAttempts: 3,
            waitingSince: Date(), delivery: .deferred, origin: .displayOnly
        )
        XCTAssertEqual(appState.pushFollowUpReminder(reminder), .skipped(.nothingPending))
    }

    // MARK: - Helpers

    private func makeAppState() -> AppState {
        let appState = AppState()
        appState.aiworkStateDirOverride = "/nonexistent/codeisland-tests/agentix"
        return appState
    }

    private func startFollowUps(_ appState: AppState) -> FollowUpReminderController {
        let followUps = appState.followUps
        followUps.armsTimer = false
        followUps.clock = { [unowned self] in self.followUpNow }
        followUps.intervalProvider = { 60 }
        followUps.isHeldBack = { true }
        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        followUps.playSound = { _ in }
        PushNotifier.shared.clock = { [unowned self] in self.followUpNow }
        appState.connectPushToFollowUps()
        return followUps
    }

    private func answerIn(_ app: String) -> String {
        String(format: L10n.shared["push_msg_answer_in"], app)
    }

    private func waitForRequests(_ count: Int) async {
        for _ in 0..<200 where transport.requests.count < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func sentBodies() -> [[String: Any]] {
        transport.requests.compactMap(\.jsonBody)
    }

    private func makeEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    private func coworkAudit(_ events: CoworkAuditEvent...) -> CoworkAuditState {
        var audit = CoworkAuditState()
        audit.apply(.userPrompt(text: "ship it", isSynthetic: false))
        audit.apply(events)
        return audit
    }

    private func coworkUpdate(
        _ audit: CoworkAuditState,
        isLive: Bool = true,
        permissionsRequested: Int = 0
    ) -> CoworkSessionWatcher.SessionUpdate {
        let metadata = CoworkSessionMetadata(
            sessionId: storeId,
            cliSessionId: "cli-display-only-push",
            title: "Ship it",
            cwd: "/sessions/calm-bright-heron",
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
            lastActivity: isLive ? nil : Date(timeIntervalSinceNow: -30),
            isLive: isLive,
            promptsStarted: 0,
            turnsCompleted: 0,
            permissionsRequested: permissionsRequested
        )
    }

    private func startCursorSession(_ appState: AppState) {
        let path = "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorId)/\(cursorId).jsonl"
        var session = SessionSnapshot()
        session.source = "cursor"
        session.status = .processing
        session.transcriptPath = path
        session.termBundleId = "com.todesktop.230313mzl4w4u92"
        appState.sessions[cursorId] = session
        appState.attachedTranscriptPaths[cursorId] = path
    }

    private func aiworkEvent(_ appState: AppState, _ name: String, data: String) {
        let json = #"{"kind":"event","category":"session","operation":"sessions.watch","event":{"name":""#
            + name
            + #""},"data":{"#
            + data
            + #","session":{"session_id":"acp:coder:push","cwd":"/tmp/proj","title":"Ship","client_type":"AiWorkGUI"}},"meta":{"session_id":"acp:coder:push"}}"#
        guard let frame = AiWorkWatchClient.parseFrame(Data(json.utf8)) else {
            return XCTFail("unparseable frame: \(json)")
        }
        appState.handleAiWorkStreamEvent(name: name, frame: frame, agentId: "coder")
    }
}
