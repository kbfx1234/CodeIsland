import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Records requests instead of sending them: nothing here reaches a real
/// push service.
private final class ReminderRecordingTransport: PushTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PushHTTPRequest] = []

    var requests: [PushHTTPRequest] { lock.withLock { recorded } }

    func send(_ request: PushHTTPRequest) async -> PushTransportResponse {
        lock.withLock { recorded.append(request) }
        return PushTransportResponse(statusCode: 200, body: Data(#"{"code":200,"message":"success"}"#.utf8))
    }
}

/// A follow-up reminder the island keeps to itself — the session's terminal
/// is in front, the card is under the pointer — still reaches the phone when
/// nobody is at the Mac. Smart Suppress reads "the terminal is in front",
/// which an unattended Mac keeps reporting.
@MainActor
final class FollowUpReminderPushTests: XCTestCase {
    private let suiteName = "FollowUpReminderPushTests"
    private var defaults: UserDefaults!
    private var transport = ReminderRecordingTransport()
    private var presence = PushPresenceSnapshot(idleSeconds: 3_600)
    private var appState: AppState!
    private var followUps: FollowUpReminderController!
    private var now = Date(timeIntervalSinceReferenceDate: 90_000)
    private var played: [String] = []
    private var terminalInFront = true
    private var pending: [Task<Data, Never>] = []
    private var saved: [String: Any?] = [:]
    private let keys = [
        SettingsKey.autoExpandOnPermission, SettingsKey.smartSuppress, SettingsKey.completionNotificationStyle,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)

        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: SettingsKey.pushEnabled)
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "TESTKEY"
        bark.events = PushEventKind.defaultSelection
        defaults.set(PushChannelConfig.encodeList([bark]), forKey: SettingsKey.pushChannels)

        transport = ReminderRecordingTransport()
        presence = PushPresenceSnapshot(idleSeconds: 3_600)
        now = Date(timeIntervalSinceReferenceDate: 90_000)
        played = []
        terminalInFront = true
        pending = []
        let notifier = PushNotifier.shared
        notifier.resetForTesting()
        notifier.defaults = defaults
        notifier.transport = transport
        notifier.presence = { [unowned self] in self.presence }
        notifier.clock = { [unowned self] in self.now }

        appState = AppState()
        followUps = appState.followUps
        followUps.armsTimer = false
        followUps.clock = { [unowned self] in self.now }
        followUps.intervalProvider = { 60 }
        // Not locked, so the Mac does not hold reminders back: the user just
        // walked off with the agent's terminal in front.
        followUps.isHeldBack = { false }
        followUps.isPointerOverPanel = { false }
        followUps.terminalFrontmost = { [unowned self] _ in self.terminalInFront }
        followUps.tabVisible = { _ in true }  // only consulted while the app is in front
        followUps.playSound = { [unowned self] in self.played.append($0) }
        appState.connectPushToFollowUps()
    }

    override func tearDown() async throws {
        let waiters = appState.permissionQueue.map(\.event) + appState.questionQueue.map(\.event)
        for event in waiters {
            appState.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        // `try?`: a stuck request is already recorded as a failure; the
        // rest of the teardown must still run so the defaults are restored.
        for t in pending { _ = try? await awaitValue(of: t) }
        let notifier = PushNotifier.shared
        notifier.transport = URLSessionPushTransport.shared
        notifier.presence = { PushPresence.current() }
        notifier.clock = Date.init
        notifier.defaults = .standard
        notifier.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        followUps = nil
        appState = nil
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        try await super.tearDown()
    }

    func testReminderKeptOffTheMacIsPushedWhenNobodyIsThere() async throws {
        try await requestApproval("away-front")
        appState.surface = .collapsed

        await advance(60)
        XCTAssertEqual(played, [], "the island stays quiet: the terminal is in front")
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))
        await waitForReminderPushes(1)
    }

    /// A pushed reminder is a spent attempt: the phone gets at most three.
    func testPushedRemindersCountTowardsTheCap() async throws {
        try await requestApproval("away-cap")
        for _ in 0..<5 { await advance(60) }
        await waitForReminderPushes(3)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reminderPushes().count, 3)
        XCTAssertNil(followUps.armedWakeDate, "all three attempts went to the phone")
        XCTAssertEqual(played, [])
    }

    /// At the Mac with the terminal in front, Smart Suppress wins: nothing is
    /// pushed, and nothing is spent — the reminder comes back once the
    /// terminal is no longer in front.
    func testReminderKeptOffTheMacIsNotPushedWhileTheUserIsThere() async throws {
        defaults.set(false, forKey: SettingsKey.pushOnlyWhenAway)
        presence = PushPresenceSnapshot(idleSeconds: 2)
        try await requestApproval("present-front")
        appState.surface = .collapsed

        await advance(60)
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.smartSuppressed))
        XCTAssertEqual(played, [])

        terminalInFront = false
        await advance(60)
        XCTAssertEqual(played, ["PermissionRequest"])
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "present-front"))
    }

    func testPushGateDecidesOnTheLocalSuppression() {
        defaults.set(false, forKey: SettingsKey.pushOnlyWhenAway)
        let reminder = FollowUpReminder(
            kind: .completion, sessionId: "gate", attempt: 1, maxAttempts: 1,
            waitingSince: now, delivery: .onTime, locallySuppressed: true
        )
        presence = PushPresenceSnapshot(idleSeconds: 2)
        XCTAssertEqual(appState.pushFollowUpReminder(reminder), .skipped(.smartSuppressed))
        presence = PushPresenceSnapshot(screenLocked: true)
        XCTAssertEqual(appState.pushFollowUpReminder(reminder), .sent([.bark]))
    }

    // MARK: - Failed turns

    /// The turn died while the user was at the Mac (no error push), and they
    /// walked off: its follow-up, driven end to end, is never pushed as
    /// "still waiting · finished".
    func testFailedTurnIsNotRemindedAsFinishedOnThePhone() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        presence = PushPresenceSnapshot(idleSeconds: 2)
        appState.handleEvent(try stopFailure("died-unseen"))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .skipped(.userPresent))

        var handed: [FollowUpReminder] = []
        followUps.addReminderHandler { handed.append($0) }
        presence = PushPresenceSnapshot(screenLocked: true)
        await advance(60)
        XCTAssertEqual(played, [EventSoundRouting.turnFailed], "the Mac rings the error again")
        XCTAssertEqual(handed.map(\.turnFailed), [true])
        XCTAssertEqual(appState.pushFollowUpReminder(try XCTUnwrap(handed.first)), .skipped(.duplicate))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reminderPushes().count, 0)
    }

    /// Its error already reached the phone: the reminder would only repeat it.
    func testFailedTurnReminderIsNotPushedAfterItsErrorWent() throws {
        presence = PushPresenceSnapshot(screenLocked: true)
        appState.handleEvent(try stopFailure("died-pushed"))
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]))

        let reminder = FollowUpReminder(
            kind: .completion, sessionId: "died-pushed", attempt: 1, maxAttempts: 1,
            waitingSince: now, delivery: .deferred, turnFailed: true
        )
        XCTAssertEqual(appState.pushFollowUpReminder(reminder), .skipped(.duplicate))
    }

    // MARK: - Helpers

    private func stopFailure(_ sid: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "StopFailure", "session_id": sid,
            "error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached",
        ] as [String: Any])))
    }

    private func advance(_ s: TimeInterval) async {
        now = now.addingTimeInterval(s)
        await followUps.tick(now: now)
    }

    private func requestApproval(_ sid: String) async throws {
        let e = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "Bash",
            "tool_input": ["command": "make deploy"], "_term_app": "iTerm.app",
        ] as [String: Any])))
        pending.append(await startHookRequest { [appState] in appState!.handlePermissionRequest(e, continuation: $0) })
        XCTAssertNotNil(appState.pendingPermission(forSession: sid))
    }

    private func reminderPushes() -> [[String: Any]] {
        transport.requests.compactMap(\.jsonBody).filter { ($0["title"] as? String)?.hasPrefix("⏰") == true }
    }

    /// Delivery runs in a task; wait (bounded) until `count` reminders went out.
    private func waitForReminderPushes(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("expected \(count) reminder push(es)", file: file, line: line) {
            self.reminderPushes().count >= count
        }
        XCTAssertEqual(reminderPushes().count, count, file: file, line: line)
    }
}
