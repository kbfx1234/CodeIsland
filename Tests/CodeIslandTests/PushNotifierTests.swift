import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Records requests instead of sending them: nothing in this suite reaches a
/// real push service.
private final class RecordingTransport: PushTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PushHTTPRequest] = []
    private let response: PushTransportResponse

    init(response: PushTransportResponse = PushTransportResponse(
        statusCode: 200,
        body: Data(#"{"code":200,"message":"success"}"#.utf8)
    )) {
        self.response = response
    }

    var requests: [PushHTTPRequest] { lock.withLock { recorded } }

    func send(_ request: PushHTTPRequest) async -> PushTransportResponse {
        lock.withLock { recorded.append(request) }
        return response
    }
}

/// Answers with each scripted response in turn (the last one repeats);
/// records every request. Never touches the network.
private final class ScriptedTransport: PushTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PushHTTPRequest] = []
    private var script: [PushTransportResponse]

    init(_ script: [PushTransportResponse]) {
        self.script = script
    }

    var requests: [PushHTTPRequest] { lock.withLock { recorded } }

    func send(_ request: PushHTTPRequest) async -> PushTransportResponse {
        lock.withLock {
            recorded.append(request)
            return script.count > 1 ? script.removeFirst() : script[0]
        }
    }
}

/// End to end from AppState's queues to the request a channel would send.
@MainActor
final class PushNotifierTests: XCTestCase {
    private var transport = RecordingTransport()
    /// Push settings live in a private suite, never in `.standard`: a run
    /// that dies mid-test must not leave a real app (or a later suite) with
    /// push switched on and a channel configured.
    private let suiteName = "PushNotifierTests"
    private var defaults: UserDefaults!
    private var savedSmartSuppress: Any?
    private var presence = PushPresenceSnapshot(screenLocked: true)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)

        transport = RecordingTransport()
        presence = PushPresenceSnapshot(screenLocked: true)
        let notifier = PushNotifier.shared
        notifier.resetForTesting()
        notifier.defaults = defaults
        notifier.transport = transport
        notifier.presence = { [unowned self] in self.presence }
        notifier.armsCatchUpTimer = false
        defaults.set(true, forKey: SettingsKey.pushEnabled)
        configureBark()
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

    private func configureBark(events: Set<PushEventKind> = PushEventKind.defaultSelection) {
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "TESTKEY"
        bark.events = events
        defaults.set(PushChannelConfig.encodeList([bark]), forKey: SettingsKey.pushChannels)
    }

    private func makeEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    /// Delivery runs in a Task; give it a moment on the main actor.
    private func waitForRequests(_ count: Int) async {
        for _ in 0..<200 where transport.requests.count < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func sentBodies() -> [[String: Any]] {
        transport.requests.compactMap(\.jsonBody)
    }

    // MARK: Approvals

    func testQueuedPermissionPushesToolAndCommandWhenAway() async throws {
        let appState = AppState()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-perm",
            "cwd": "/tmp/push-project",
            "_source": "claude",
            "tool_name": "Bash",
            "tool_input": ["command": "git push origin main"],
        ])
        let response = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(transport.requests.first?.url.absoluteString, "https://api.day.app/push")
        XCTAssertEqual(body["title"] as? String, "🔐 Claude · push-project")
        XCTAssertEqual(body["subtitle"] as? String, "\(L10n.shared["push_msg_permission"]): Bash")
        XCTAssertEqual(body["body"] as? String, "git push origin main")
        XCTAssertEqual(body["level"] as? String, "timeSensitive")
        XCTAssertEqual(PushNotifier.shared.lastDelivery[.bark]?.result.ok, true)

        appState.approvePermission(expectedSessionId: "push-perm")
        _ = try await awaitValue(of: response)
    }

    func testNothingIsPushedWhileThePersonIsAtTheMac() async throws {
        presence = PushPresenceSnapshot(idleSeconds: 3)
        let appState = AppState()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-present",
            "tool_name": "Bash",
            "tool_input": ["command": "ls"],
        ])
        let response = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.userPresent))
        appState.denyPermission(expectedSessionId: "push-present")
        _ = try await awaitValue(of: response)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Catch-up of held-back requests

    private func queuePermission(_ appState: AppState, session: String, command: String) async throws -> Task<Data, Never> {
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": session,
            "tool_name": "Bash",
            "tool_input": ["command": command],
        ])
        return await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
    }

    /// Walked off without locking: the approval that arrives 30 s later is
    /// held back as "present", and goes to the phone once the screen locks.
    func testApprovalHeldBackWhilePresentIsPushedWhenTheScreenLocks() async throws {
        presence = PushPresenceSnapshot(idleSeconds: 30)
        let appState = AppState()
        let response = try await queuePermission(appState, session: "push-held", command: "make deploy")
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.userPresent))
        XCTAssertTrue(PushNotifier.shared.hasHeldBackRequests)
        XCTAssertNotNil(PushNotifier.shared.catchUpWakeDate, "one idle timer while something is held back")

        presence = PushPresenceSnapshot(screenLocked: true, idleSeconds: 31)
        PushNotifier.shared.userLeft()
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        XCTAssertEqual(sentBodies().first?["body"] as? String, "make deploy")
        XCTAssertFalse(PushNotifier.shared.hasHeldBackRequests)
        XCTAssertNil(PushNotifier.shared.catchUpWakeDate)

        // At most once per request: the next departure pushes nothing.
        PushNotifier.shared.userLeft()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.requests.count, 1)

        appState.denyPermission(expectedSessionId: "push-held")
        _ = try await awaitValue(of: response)
    }

    /// No lock: the timer looks when idle time could reach the threshold,
    /// and looks again later if the person touched the Mac meanwhile.
    func testIdleTimerCatchesUpOnceTheIdleThresholdIsReached() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 500_000)
        PushNotifier.shared.clock = { start }
        presence = PushPresenceSnapshot(idleSeconds: 20)
        let threshold = PushNotifier.shared.idleThreshold
        let appState = AppState()
        let response = try await queuePermission(appState, session: "push-idle", command: "rm -rf dist")
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.userPresent))
        XCTAssertEqual(PushNotifier.shared.catchUpWakeDate, start.addingTimeInterval(threshold - 20 + 1))

        presence = PushPresenceSnapshot(idleSeconds: 2)  // back at the keyboard
        PushNotifier.shared.catchUpIfAway()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(PushNotifier.shared.catchUpWakeDate, start.addingTimeInterval(threshold - 2 + 1))

        presence = PushPresenceSnapshot(idleSeconds: threshold + 1)
        PushNotifier.shared.catchUpIfAway()
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        XCTAssertNil(PushNotifier.shared.catchUpWakeDate)
        await waitForRequests(1)

        appState.denyPermission(expectedSessionId: "push-idle")
        _ = try await awaitValue(of: response)
    }

    /// Answered at the Mac: out of the set, the timer goes, nothing is sent.
    func testAnsweredHeldBackRequestIsDroppedWithItsTimer() async throws {
        presence = PushPresenceSnapshot(idleSeconds: 5)
        let appState = AppState()
        let response = try await queuePermission(appState, session: "push-answered", command: "ls")
        XCTAssertTrue(PushNotifier.shared.hasHeldBackRequests)

        appState.approvePermission(expectedSessionId: "push-answered")
        _ = try await awaitValue(of: response)
        // Dropped once the queue change settles, on a later main-actor turn.
        await waitUntil("the answered request stays held back") { !PushNotifier.shared.hasHeldBackRequests }
        XCTAssertNil(PushNotifier.shared.catchUpWakeDate)

        presence = PushPresenceSnapshot(screenLocked: true)
        PushNotifier.shared.userLeft()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// Only waiting approvals / questions are caught up; a finished turn
    /// skipped while present arms nothing, and neither does push switched off.
    func testOnlyBlockingRequestsAreHeldBack() async throws {
        presence = PushPresenceSnapshot(idleSeconds: 5)
        let appState = AppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "push-held-stop",
            "last_assistant_message": "Done.",
        ]))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.userPresent))
        XCTAssertFalse(PushNotifier.shared.hasHeldBackRequests)
        XCTAssertNil(PushNotifier.shared.catchUpWakeDate)

        defaults.set(false, forKey: SettingsKey.pushEnabled)
        let response = try await queuePermission(appState, session: "push-held-off", command: "ls")
        XCTAssertFalse(PushNotifier.shared.hasHeldBackRequests)
        XCTAssertNil(PushNotifier.shared.catchUpWakeDate)
        appState.denyPermission(expectedSessionId: "push-held-off")
        _ = try await awaitValue(of: response)
    }

    func testDisabledPushNeverDecidesAnything() async throws {
        defaults.set(false, forKey: SettingsKey.pushEnabled)
        let appState = AppState()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-off",
            "tool_name": "Bash",
            "tool_input": ["command": "ls"],
        ])
        let response = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertNil(PushNotifier.shared.lastDecision)
        appState.denyPermission(expectedSessionId: "push-off")
        _ = try await awaitValue(of: response)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// Each approval is its own push; only a replay of the same request
    /// (same tool call id) is one.
    func testEachApprovalOfASessionPushesOnce() async throws {
        let appState = AppState()
        var responses: [Task<Data, Never>] = []
        for (index, command) in ["ls", "pwd"].enumerated() {
            let event = try makeEvent([
                "hook_event_name": "PermissionRequest",
                "session_id": "push-burst",
                "tool_name": "Bash",
                "tool_use_id": "tool-\(index)",
                "tool_input": ["command": command],
            ])
            responses.append(await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) })
            XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]), command)
        }
        await waitForRequests(2)
        XCTAssertEqual(sentBodies().compactMap { $0["body"] as? String }, ["ls", "pwd"])

        // The hook bridge replays the first request: same id, same push.
        PushNotifier.shared.notify(
            AppState.pushContent(forPermission: appState.permissionQueue[0].event, cwd: nil),
            subject: appState.pushSubject(for: "push-burst"),
            request: appState.pushRequest(forPermission: appState.permissionQueue[0].event, sessionId: "push-burst")
        )
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.duplicate))

        appState.denyPermission(expectedSessionId: "push-burst")
        appState.denyPermission(expectedSessionId: "push-burst")
        for response in responses { _ = try await awaitValue(of: response) }
        XCTAssertEqual(transport.requests.count, 2)
    }

    /// Answered on the iPhone, and the agent asks again 40 s later — even
    /// the very same command, from an agent that sends no tool call id.
    func testTheNextApprovalAfterAnAnsweredOneIsPushed() async throws {
        let appState = AppState()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-again",
            "tool_name": "Bash",
            "tool_input": ["command": "npm test"],
        ])
        let first = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        appState.approvePermission(expectedSessionId: "push-again")
        _ = try await awaitValue(of: first)
        // The answered request frees its slot once the queue change settles.
        PushNotifier.shared.forgetAnsweredRequests()

        let second = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]), "a new request, not a repeat")
        await waitForRequests(2)
        appState.denyPermission(expectedSessionId: "push-again")
        _ = try await awaitValue(of: second)
    }

    /// A team chat added with default settings hears that an approval is
    /// waiting, not the command; the phone still gets the command.
    func testTeamChatGetsTheHeadlineAndThePhoneTheDetails() async throws {
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "TESTKEY"
        var dingtalk = PushChannelConfig(kind: .dingtalk)
        dingtalk.enabled = true
        dingtalk.endpoint = "https://oapi.dingtalk.com/robot/send?access_token=abc"
        defaults.set(PushChannelConfig.encodeList([bark, dingtalk]), forKey: SettingsKey.pushChannels)

        let appState = AppState()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-team",
            "cwd": "/tmp/push-team",
            "tool_name": "Bash",
            "tool_input": ["command": "cat > deploy.key <<EOF\nPRIVATE KEY BODY\nEOF"],
        ])
        let response = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark, .dingtalk]))
        await waitForRequests(2)

        let barkBody = try XCTUnwrap(transport.requests.first { $0.url.host == "api.day.app" }?.jsonBody)
        XCTAssertEqual(barkBody["body"] as? String, "cat > deploy.key <<EOF …")
        let dingBody = try XCTUnwrap(transport.requests.first { $0.url.host == "oapi.dingtalk.com" }?.jsonBody)
        let content = try XCTUnwrap((dingBody["text"] as? [String: Any])?["content"] as? String)
        XCTAssertEqual(content, "🔐 Claude · push-team\n\(L10n.shared["push_msg_permission"]): Bash\n\(PushRequestBuilder.keywordFooter)")

        appState.denyPermission(expectedSessionId: "push-team")
        _ = try await awaitValue(of: response)
    }

    func testChannelEventFilterIsHonoured() async throws {
        configureBark(events: [.completion])
        let appState = AppState()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-filtered",
            "tool_name": "Bash",
            "tool_input": ["command": "ls"],
        ])
        let response = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.noChannel))
        appState.denyPermission(expectedSessionId: "push-filtered")
        _ = try await awaitValue(of: response)
    }

    // MARK: Questions

    func testAskUserQuestionPushesNumberedOptions() async throws {
        let appState = AppState()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-ask",
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": "Which database?",
                    "header": "DB",
                    "multiSelect": false,
                    "options": [
                        ["label": "Postgres", "description": "Server"],
                        ["label": "SQLite", "description": "File"],
                    ],
                ]],
            ],
        ])
        let response = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        await waitForRequests(1)

        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["subtitle"] as? String, L10n.shared["push_msg_question"])
        XCTAssertEqual(body["body"] as? String, "Which database?\n1. Postgres\n2. SQLite")

        appState.skipQuestion(expectedSessionId: "push-ask")
        _ = try await awaitValue(of: response)
    }

    /// With "auto-expand on question" off the card waits behind a badge —
    /// that is no reason to keep the question off the phone. Only Smart
    /// Suppress (its terminal in front) is.
    func testAskUserQuestionPushIgnoresTheAutoExpandSwitch() async throws {
        let savedAutoExpand = UserDefaults.standard.object(forKey: SettingsKey.autoExpandOnQuestion)
        defer {
            if let savedAutoExpand {
                UserDefaults.standard.set(savedAutoExpand, forKey: SettingsKey.autoExpandOnQuestion)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.autoExpandOnQuestion)
            }
        }
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        defaults.set(false, forKey: SettingsKey.pushOnlyWhenAway)
        presence = PushPresenceSnapshot(idleSeconds: 3)

        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in false }
        func ask(_ session: String) async throws -> Task<Data, Never> {
            let event = try makeEvent([
                "hook_event_name": "PermissionRequest",
                "session_id": session,
                "_term_app": "iTerm.app",
                "tool_name": "AskUserQuestion",
                "tool_input": ["questions": [["question": "Which database?", "header": "DB", "options": [["label": "Postgres"]]]]],
            ])
            return await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
        }
        let first = try await ask("push-ask-badge")
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        appState.skipQuestion(expectedSessionId: "push-ask-badge")
        _ = try await awaitValue(of: first)

        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        appState.questionTerminalFrontmostDetector = { _ in true }
        let second = try await ask("push-ask-terminal")
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.smartSuppressed))
        appState.skipQuestion(expectedSessionId: "push-ask-terminal")
        _ = try await awaitValue(of: second)
    }

    // MARK: Completion and errors

    func testStopPushesThisTurnsReply() async throws {
        let appState = AppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "push-stop",
            "prompt": "fix it",
        ]))
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "push-stop",
            "last_assistant_message": "**Fixed** the crash in the parser.",
        ]))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["subtitle"] as? String, L10n.shared["push_msg_completion"])
        XCTAssertEqual(body["body"] as? String, "Fixed the crash in the parser.")
        XCTAssertEqual(body["level"] as? String, "active")
    }

    /// A pi-subagents child (it names its parent) reports to the parent, not
    /// to the user: neither its finished nor its failed turn pushes (#378).
    func testChildTurnsPushNothingButTheParentsDoes() async throws {
        let appState = AppState()
        let parent = "pi-push-parent"
        let child: [String: Any] = [
            "session_id": "pi-push-child",
            "_source": "pi",
            DeclaredSubsession.parentKey: parent,
            "agent_type": "worker",
        ]
        appState.handleEvent(try makeEvent(child.merging([
            "hook_event_name": "Stop",
            "last_assistant_message": "child done",
        ]) { _, new in new }))
        appState.handleEvent(try makeEvent(child.merging([
            "hook_event_name": "StopFailure",
            "error": "rate_limit",
            "last_assistant_message": "API Error: Rate limit reached",
        ]) { _, new in new }))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requests.count, 0)

        appState.handleEvent(try makeEvent([
            "hook_event_name": "Stop",
            "session_id": parent,
            "_source": "pi",
            "last_assistant_message": "all done",
        ]))
        await waitForRequests(1)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(sentBodies().first?["body"] as? String, "all done")
    }

    func testInterruptedTurnIsNotPushedAsFinished() throws {
        let appState = AppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "push-esc",
            "stop_reason": "user",
        ]))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.interrupted))
    }

    func testStopFailurePushesTheErrorInsteadOfACompletion() async throws {
        let appState = AppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "StopFailure",
            "session_id": "push-fail",
            "error": "rate_limit",
            "last_assistant_message": "API Error: Rate limit reached",
        ]))
        await waitForRequests(1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requests.count, 1, "one push for the failed turn, not error + finished")
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["subtitle"] as? String, "\(L10n.shared["push_msg_error"]) (rate_limit)")
        XCTAssertEqual(body["body"] as? String, "API Error: Rate limit reached")
    }

    /// Cowork turns end outside the hook reducer; they push all the same.
    func testCoworkTurnPushesItsReply() async throws {
        let appState = AppState()
        let metadata = CoworkSessionMetadata(
            sessionId: "local_push-cowork",
            cliSessionId: "push-cowork-cli",
            title: "Installer inventory",
            cwd: "/sessions/bold-inspiring-tesla",
            userSelectedFolders: ["/Users/alice/code/app"],
            model: "claude-opus-4-5-20251101",
            createdAt: Date(timeIntervalSinceNow: -3600),
            lastActivityAt: Date(timeIntervalSinceNow: -60),
            isArchived: false,
            sessionType: nil
        )
        var audit = CoworkAuditState()
        audit.apply([
            CoworkAuditFixture.userPrompt,
            CoworkAuditFixture.assistantReply,
            CoworkAuditFixture.resultSuccess,
        ].map { CoworkAuditParser.event(fromLine: Data($0.utf8)) })
        appState.applyCoworkUpdate(CoworkSessionWatcher.SessionUpdate(
            sessionId: metadata.sessionId,
            metadata: metadata,
            audit: audit,
            transcriptPath: nil,
            lastActivity: nil,
            isLive: true,
            promptsStarted: 1,
            turnsCompleted: 1,
            permissionsRequested: 0
        ))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["subtitle"] as? String, L10n.shared["push_msg_completion"])
        XCTAssertEqual(body["body"] as? String, "Found a.dmg")

        // The next turn fails: its own error text, never the previous reply.
        audit.apply(.userPrompt(text: "and again", isSynthetic: false))
        audit.apply(.turnEnded(isError: true, resultText: "API Error: Overloaded"))
        appState.applyCoworkUpdate(CoworkSessionWatcher.SessionUpdate(
            sessionId: metadata.sessionId,
            metadata: metadata,
            audit: audit,
            transcriptPath: nil,
            lastActivity: nil,
            isLive: true,
            promptsStarted: 1,
            turnsCompleted: 1,
            permissionsRequested: 0
        ))
        await waitForRequests(2)
        let failed = try XCTUnwrap(sentBodies().last)
        XCTAssertEqual(failed["subtitle"] as? String, L10n.shared["push_msg_error"])
        XCTAssertEqual(failed["body"] as? String, "API Error: Overloaded")
    }

    /// With no error text of its own, a failed turn says only that it failed.
    func testTurnFailureWithoutTextDoesNotReuseTheLastReply() async throws {
        let appState = AppState()
        appState.sessions["push-no-text"] = SessionSnapshot()
        appState.sessions["push-no-text"]?.lastAssistantMessage = "Reply from the turn before"
        appState.pushTurnEnded(.init(kind: .error, smartSuppressed: false), sessionId: "push-no-text")
        await waitForRequests(1)
        let body = try XCTUnwrap(sentBodies().first)
        XCTAssertEqual(body["body"] as? String, L10n.shared["push_msg_error"])
        XCTAssertNil(body["subtitle"])

        XCTAssertEqual(AppState.aiworkFailureText(["error": .object(["message": .string(" model overloaded ")])]), "model overloaded")
        XCTAssertEqual(AppState.aiworkFailureText(["reason": .string("quota exceeded")]), "quota exceeded")
        XCTAssertNil(AppState.aiworkFailureText(["final_text": .string("half a reply")]))
        XCTAssertNil(AppState.aiworkFailureText(nil))
    }

    // MARK: Follow-up reminders

    private var followUpNow = Date(timeIntervalSinceReferenceDate: 80_000)

    /// A reminder that came due while the Mac was locked goes to the phone
    /// with the same command as the first push and how long it has waited.
    func testDeferredApprovalReminderIsPushedWithTheWaitingRequest() async throws {
        let appState = AppState()
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

        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "push-remind",
            "tool_name": "Bash",
            "tool_input": ["command": "make deploy"],
        ])
        let response = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        await waitForRequests(1)

        followUpNow = followUpNow.addingTimeInterval(61)
        await followUps.tick(now: followUpNow)
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]), "a reminder is its own kind, not deduped against the approval")
        await waitForRequests(2)
        let reminder = try XCTUnwrap(sentBodies().last)
        XCTAssertEqual(reminder["title"] as? String, "⏰ Claude")
        XCTAssertEqual(reminder["subtitle"] as? String, "\(L10n.shared["push_msg_reminder"]) · \(String(format: L10n.shared["push_msg_waiting_minutes"], 1))")
        XCTAssertEqual(reminder["body"] as? String, "\(L10n.shared["push_msg_permission"]): Bash\nmake deploy")
        XCTAssertEqual(reminder["level"] as? String, "timeSensitive")

        appState.denyPermission(expectedSessionId: "push-remind")
        _ = try await awaitValue(of: response)
    }

    func testCatchUpAndAnsweredRemindersAreNotPushed() {
        let appState = AppState()
        let catchUp = FollowUpReminder(
            kind: .approval, sessionId: "x", attempt: 1, maxAttempts: 3,
            waitingSince: Date(), delivery: .catchUp
        )
        XCTAssertEqual(appState.pushFollowUpReminder(catchUp), .skipped(.userPresent))
        let answered = FollowUpReminder(
            kind: .question, sessionId: "gone", attempt: 2, maxAttempts: 3,
            waitingSince: Date(), delivery: .deferred
        )
        XCTAssertEqual(appState.pushFollowUpReminder(answered), .skipped(.nothingPending))
    }

    /// An unseen finished turn gets one reminder — unless its own completion
    /// push already reached the phone.
    func testCompletionReminderOnlyWhenTheCompletionWasNotPushed() async throws {
        let appState = AppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "push-seen",
            "last_assistant_message": "Done.",
        ]))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForDelivery()
        let afterPushed = FollowUpReminder(
            kind: .completion, sessionId: "push-seen", attempt: 1, maxAttempts: 1,
            waitingSince: Date(), delivery: .deferred
        )
        XCTAssertEqual(appState.pushFollowUpReminder(afterPushed), .skipped(.duplicate))

        // Present at the Mac when the turn ended, gone by the time it is due.
        presence = PushPresenceSnapshot(idleSeconds: 1)
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "push-unseen",
            "last_assistant_message": "Refactor finished.",
        ]))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.userPresent))
        presence = PushPresenceSnapshot(screenLocked: true)
        let unseen = FollowUpReminder(
            kind: .completion, sessionId: "push-unseen", attempt: 1, maxAttempts: 1,
            waitingSince: Date(), delivery: .deferred
        )
        XCTAssertEqual(appState.pushFollowUpReminder(unseen), .sent([.bark]))
        await waitForRequests(2)
        let reminder = try XCTUnwrap(sentBodies().last)
        XCTAssertEqual(reminder["level"] as? String, "active", "a finished turn does not break through Focus")
        XCTAssertEqual(reminder["body"] as? String, "\(L10n.shared["push_msg_completion"])\nRefactor finished.")
    }

    private func waitForDelivery(_ channel: PushChannelKind = .bark) async {
        await waitUntil("no delivery recorded for \(channel)") { PushNotifier.shared.lastDelivery[channel] != nil }
    }

    /// The completion push was admitted but never arrived: the reminder is
    /// the only word the phone gets, so it goes.
    func testCompletionReminderStillGoesWhenTheCompletionPushFailed() async throws {
        PushNotifier.shared.transport = RecordingTransport(response: PushTransportResponse(
            statusCode: nil,
            errorDescription: "The Internet connection appears to be offline."
        ))
        let appState = AppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "Stop",
            "session_id": "push-lost",
            "last_assistant_message": "Done.",
        ]))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForDelivery()
        XCTAssertEqual(PushNotifier.shared.lastDelivery[.bark]?.result.ok, false)

        PushNotifier.shared.transport = transport
        let reminder = FollowUpReminder(
            kind: .completion, sessionId: "push-lost", attempt: 1, maxAttempts: 1,
            waitingSince: Date(), delivery: .deferred
        )
        XCTAssertEqual(appState.pushFollowUpReminder(reminder), .sent([.bark]))
    }

    /// A turn that failed gets no "still waiting · finished" — whether its
    /// error push went out (away) or was held back (present).
    func testFailedTurnGetsNoFinishedReminder() async throws {
        let appState = AppState()
        for (session, present) in [("push-failed-away", false), ("push-failed-present", true)] {
            presence = present ? PushPresenceSnapshot(idleSeconds: 2) : PushPresenceSnapshot(screenLocked: true)
            appState.handleEvent(try makeEvent([
                "hook_event_name": "StopFailure",
                "session_id": session,
                "error": "rate_limit",
                "last_assistant_message": "API Error: Rate limit reached",
            ]))
            presence = PushPresenceSnapshot(screenLocked: true)
            let reminder = FollowUpReminder(
                kind: .completion, sessionId: session, attempt: 1, maxAttempts: 1,
                waitingSince: Date(), delivery: .deferred
            )
            XCTAssertEqual(appState.pushFollowUpReminder(reminder), .skipped(.duplicate), session)
        }
    }

    /// A channel that only takes finished turns still hears that a turn
    /// ended — on an error.
    func testFailedTurnReachesAChannelThatOnlyTakesFinishedTurns() async throws {
        configureBark(events: [.completion])
        let appState = AppState()
        appState.handleEvent(try makeEvent([
            "hook_event_name": "StopFailure",
            "session_id": "push-fail-completion-only",
            "error": "overloaded",
            "last_assistant_message": "API Error: Overloaded",
        ]))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForRequests(1)
        XCTAssertEqual(sentBodies().first?["subtitle"] as? String, "\(L10n.shared["push_msg_error"]) (overloaded)")
    }

    func testReminderCheckboxCanBeTurnedOff() {
        configureBark(events: [.permission, .question, .completion, .error])
        let appState = AppState()
        let reminder = FollowUpReminder(
            kind: .completion, sessionId: "push-off-reminder", attempt: 1, maxAttempts: 1,
            waitingSince: Date(), delivery: .onTime
        )
        XCTAssertEqual(appState.pushFollowUpReminder(reminder), .skipped(.noChannel))
    }

    // MARK: Volume

    private var fakeNow = Date(timeIntervalSinceReferenceDate: 700_000)
    private var slept: [TimeInterval] = []
    private var sleepGate: CheckedContinuation<Void, Never>?

    /// The notifier's clock and waits, under the test's control: a wait is
    /// recorded, parks until `releaseSleep()`, then moves the clock on.
    private func controlTime() {
        PushNotifier.shared.clock = { [unowned self] in self.fakeNow }
        PushNotifier.shared.sleep = { [unowned self] seconds in
            self.slept.append(seconds)
            await withCheckedContinuation { self.sleepGate = $0 }
            self.fakeNow = self.fakeNow.addingTimeInterval(seconds)
        }
    }

    private func releaseSleep() async {
        await waitUntil("the notifier never started waiting") { sleepGate != nil }
        let gate = sleepGate
        sleepGate = nil
        gate?.resume()
    }

    private func waiting(_ content: PushContent, isWaiting: @escaping () -> Bool = { true }) -> PushPendingRequest {
        PushPendingRequest(key: UUID().uuidString) { isWaiting() ? content : nil }
    }

    private func configureDingTalk() {
        var dingtalk = PushChannelConfig(kind: .dingtalk)
        dingtalk.enabled = true
        dingtalk.endpoint = "https://oapi.dingtalk.com/robot/send?access_token=abc"
        defaults.set(PushChannelConfig.encodeList([dingtalk]), forKey: SettingsKey.pushChannels)
    }

    private func dingTalkContents() -> [String] {
        sentBodies().compactMap { ($0["text"] as? [String: Any])?["content"] as? String }
    }

    /// A flood of finished turns is capped; approvals are never refused.
    func testGlobalCapDropsFinishedTurnsButNeverApprovals() {
        controlTime()
        let notifier = PushNotifier.shared
        for i in 0..<PushThrottle.global.count {
            XCTAssertEqual(notifier.notify(.completion(summary: "done"), subject: PushSubject(sessionId: "cap-\(i)", agent: "Claude")), .sent([.bark]))
        }
        XCTAssertEqual(notifier.notify(.completion(summary: "done"), subject: PushSubject(sessionId: "cap-x", agent: "Claude")), .skipped(.rateLimited))
        let approval = PushContent.permission(tool: "Bash", detail: "make deploy")
        XCTAssertEqual(notifier.notify(approval, subject: PushSubject(sessionId: "cap-y", agent: "Claude"), request: waiting(approval)), .sent([.bark]))
        let question = PushContent.question(items: [PushQuestionItem(question: "Ship?")], isSecret: false)
        XCTAssertEqual(notifier.notify(question, subject: PushSubject(sessionId: "cap-z", agent: "Claude"), request: waiting(question)), .sent([.bark]))
    }

    /// DingTalk silences a robot for 10 minutes past 20 a minute. Over its
    /// limit, an approval waits for room; a finished turn is dropped.
    func testTeamChatQueuesApprovalsOverItsLimitAndDropsTheRest() async throws {
        controlTime()
        configureDingTalk()
        let notifier = PushNotifier.shared
        let limit = PushChannelKind.dingtalk.rateLimits[0].count
        for i in 0..<limit {
            let approval = PushContent.permission(tool: "Bash", detail: "step \(i)")
            XCTAssertEqual(notifier.notify(approval, subject: PushSubject(sessionId: "ding-\(i)", agent: "Claude"), request: waiting(approval)), .sent([.dingtalk]))
        }
        await waitForRequests(limit)

        let late = PushContent.permission(tool: "Bash", detail: "the late one")
        XCTAssertEqual(notifier.notify(late, subject: PushSubject(sessionId: "ding-late", agent: "Claude"), request: waiting(late)), .sent([.dingtalk]))
        notifier.notify(.completion(summary: "done"), subject: PushSubject(sessionId: "ding-done", agent: "Claude"))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.requests.count, limit, "nothing more this minute")

        await releaseSleep()
        await waitForRequests(limit + 1)
        XCTAssertEqual(slept, [60], "until the first send of the minute ages out")
        XCTAssertEqual(transport.requests.count, limit + 1)
        XCTAssertTrue(dingTalkContents().last?.contains("🔐 Claude") == true)
        XCTAssertFalse(dingTalkContents().contains { $0.contains(L10n.shared["push_msg_completion"]) }, "the finished turn was dropped")
    }

    /// An approval queued behind the limit and answered meanwhile is not sent.
    func testQueuedApprovalAnsweredMeanwhileIsDropped() async throws {
        controlTime()
        configureDingTalk()
        let notifier = PushNotifier.shared
        let limit = PushChannelKind.dingtalk.rateLimits[0].count
        for i in 0..<limit {
            let approval = PushContent.permission(tool: "Bash", detail: "step \(i)")
            notifier.notify(approval, subject: PushSubject(sessionId: "answered-\(i)", agent: "Claude"), request: waiting(approval))
        }
        await waitForRequests(limit)

        var stillWaiting = true
        let late = PushContent.permission(tool: "Bash", detail: "answered on the Mac")
        notifier.notify(late, subject: PushSubject(sessionId: "answered-late", agent: "Claude"), request: waiting(late) { stillWaiting })
        stillWaiting = false
        notifier.forgetAnsweredRequests()
        await releaseSleep()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requests.count, limit)
    }

    /// Slack takes one message a second: a second finished turn in the same
    /// second waits a moment rather than being dropped.
    func testPerSecondLimitDelaysRatherThanDrops() async throws {
        controlTime()
        var slack = PushChannelConfig(kind: .slack)
        slack.enabled = true
        slack.endpoint = "https://hooks.slack.com/services/T0/B0/xyz"
        defaults.set(PushChannelConfig.encodeList([slack]), forKey: SettingsKey.pushChannels)
        let notifier = PushNotifier.shared
        notifier.notify(.completion(summary: "one"), subject: PushSubject(sessionId: "slack-1", agent: "Claude"))
        notifier.notify(.completion(summary: "two"), subject: PushSubject(sessionId: "slack-2", agent: "Claude"))
        await waitForRequests(1)
        await releaseSleep()
        await waitForRequests(2)
        XCTAssertEqual(slept, [1])
        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: Retry

    private let barkOK = PushTransportResponse(statusCode: 200, body: Data(#"{"code":200,"message":"success"}"#.utf8))

    private func waitFor(_ scripted: ScriptedTransport, _ count: Int) async {
        await waitUntil("expected \(count) requests") { scripted.requests.count >= count }
    }

    /// A 503 on an approval: one more try 5 s later, which lands.
    func testApprovalIsRetriedOnceAfterAServerError() async {
        controlTime()
        let scripted = ScriptedTransport([PushTransportResponse(statusCode: 503, body: Data("busy".utf8)), barkOK])
        PushNotifier.shared.transport = scripted
        let approval = PushContent.permission(tool: "Bash", detail: "make deploy")
        PushNotifier.shared.notify(approval, subject: PushSubject(sessionId: "retry-1", agent: "Claude"), request: waiting(approval))
        await waitFor(scripted, 1)
        await releaseSleep()
        await waitFor(scripted, 2)
        XCTAssertEqual(slept, [PushRetryPolicy.delay])
        XCTAssertEqual(scripted.requests.count, 2)
        XCTAssertEqual(scripted.requests[0].body, scripted.requests[1].body)
        await waitUntil("the retry's delivery was never recorded") {
            PushNotifier.shared.lastDelivery[.bark]?.result.ok == true
        }
    }

    /// 429 with Retry-After is honoured (capped); a second failure is final.
    func testRateLimitedErrorPushWaitsAsToldAndRetriesOnlyOnce() async {
        controlTime()
        let scripted = ScriptedTransport([PushTransportResponse(statusCode: 429, retryAfter: 12)])
        PushNotifier.shared.transport = scripted
        PushNotifier.shared.notify(.error(type: "overloaded", detail: nil), subject: PushSubject(sessionId: "retry-2", agent: "Claude"))
        await waitFor(scripted, 1)
        await releaseSleep()
        await waitFor(scripted, 2)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(slept, [12])
        XCTAssertEqual(scripted.requests.count, 2, "one retry, no more")
    }

    /// A finished turn is not retried; neither is a 4xx.
    func testCompletionsAndClientErrorsAreNotRetried() async {
        controlTime()
        let scripted = ScriptedTransport([PushTransportResponse(statusCode: 500)])
        PushNotifier.shared.transport = scripted
        PushNotifier.shared.notify(.completion(summary: "done"), subject: PushSubject(sessionId: "retry-3", agent: "Claude"))
        await waitFor(scripted, 1)

        let rejected = ScriptedTransport([PushTransportResponse(statusCode: 400, body: Data(#"{"code":400,"message":"bad key"}"#.utf8))])
        PushNotifier.shared.transport = rejected
        let approval = PushContent.permission(tool: "Bash", detail: "ls")
        PushNotifier.shared.notify(approval, subject: PushSubject(sessionId: "retry-4", agent: "Claude"), request: waiting(approval))
        await waitFor(rejected, 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(scripted.requests.count, 1)
        XCTAssertEqual(rejected.requests.count, 1)
        XCTAssertTrue(slept.isEmpty)
    }

    // MARK: Send test

    func testSendTestReportsTheServersOwnError() async {
        let failing = RecordingTransport(response: PushTransportResponse(
            statusCode: 200,
            body: Data(#"{"errcode":310000,"errmsg":"sign not match"}"#.utf8)
        ))
        PushNotifier.shared.transport = failing
        var dingtalk = PushChannelConfig(kind: .dingtalk)
        dingtalk.endpoint = "https://oapi.dingtalk.com/robot/send?access_token=abc"
        dingtalk.secret = "SECxyz"

        let result = await PushNotifier.shared.sendTest(dingtalk)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.summary, "HTTP 200 · errcode 310000: sign not match")
        XCTAssertEqual(failing.requests.count, 1)
        XCTAssertEqual(PushNotifier.shared.lastDelivery[.dingtalk]?.result, result)
    }

    func testSendTestExplainsAMissingSetting() async {
        let result = await PushNotifier.shared.sendTest(PushChannelConfig(kind: .telegram))
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.statusCode)
        XCTAssertEqual(result.message, L10n.shared["push_problem_missingBotToken"])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Settings

    func testOnlyWhenAwayDefaultsOnEvenBeforeDefaultsAreRegistered() {
        defaults.removeObject(forKey: SettingsKey.pushOnlyWhenAway)
        XCTAssertTrue(PushNotifier.shared.onlyWhenAway)
        XCTAssertEqual(PushNotifier.shared.idleThreshold, TimeInterval(SettingsDefaults.pushAwayIdleMinutes * 60))
    }

    /// Device key, ntfy topic, webhook URLs, tokens and secrets are dots on
    /// screen until the eye is clicked; the rest stays readable.
    func testCredentialFieldsAreMaskedInSettings() {
        for kind in PushChannelKind.allCases {
            let fields = PushFieldSpec.fields(for: kind)
            XCTAssertEqual(Set(fields.map(\.key)).count, fields.count, "\(kind) field keys are unique")
            for spec in fields {
                XCTAssertNotNil(L10n.strings["en"]?[spec.key], spec.key)
                if spec.value == \PushChannelConfig.token || spec.value == \PushChannelConfig.secret {
                    XCTAssertTrue(spec.masked, "\(kind) \(spec.key)")
                }
            }
            let masked = Set(fields.filter(\.masked).map(\.key))
            switch kind {
            case .bark: XCTAssertEqual(masked, ["push_field_device_key"])
            case .ntfy: XCTAssertEqual(masked, ["push_field_topic", "push_field_token"])
            case .dingtalk, .feishu: XCTAssertEqual(masked, ["push_field_webhook", "push_field_secret"])
            case .wecom, .slack: XCTAssertEqual(masked, ["push_field_webhook"])
            case .telegram: XCTAssertEqual(masked, ["push_field_bot_token"])
            }
        }
    }

    func testPushL10nKeysExistInAllLanguages() {
        let english = L10n.strings["en"] ?? [:]
        let pushKeys = english.keys.filter { $0.hasPrefix("push_") }
        XCTAssertGreaterThan(pushKeys.count, 50)
        for kind in PushEventKind.allCases {
            XCTAssertNotNil(english["push_event_\(kind.rawValue)"], "push_event_\(kind.rawValue)")
        }
        for kind in PushChannelKind.allCases {
            XCTAssertNotNil(english["push_channel_\(kind.rawValue)"])
            XCTAssertNotNil(english["push_hint_\(kind.rawValue)"])
        }
        for problem in [PushConfigProblem.missingDeviceKey, .missingTopic, .missingWebhook, .missingBotToken, .missingChatId, .invalidURL, .ntfyTopicMismatch] {
            XCTAssertNotNil(english["push_problem_\(problem.rawValue)"])
        }
        for (language, table) in L10n.strings {
            for key in pushKeys {
                XCTAssertNotNil(table[key], "\(language) missing \(key)")
            }
        }
    }
}
