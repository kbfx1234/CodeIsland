import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Claude Desktop Cowork cards: how watcher updates become `claude` sessions
/// hosted by Claude Desktop, and the ghost-card / duplicate-card guarantees.
@MainActor
final class AppStateCoworkWatchTests: XCTestCase {

    private let storeId = "local_f421aa51-3c78-4391-bc5e-3a05c2218bee"
    private let cliSessionId = "d0a5dc71-0311-45bb-87b4-0ff74229f6ca"
    private var key: String { AppState.coworkSessionKey(storeId) }

    override func setUp() {
        super.setUp()
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
        super.tearDown()
    }

    private func metadata(
        storeId: String? = nil,
        isArchived: Bool = false,
        sessionType: String? = nil
    ) -> CoworkSessionMetadata {
        CoworkSessionMetadata(
            sessionId: storeId ?? self.storeId,
            cliSessionId: cliSessionId,
            title: "Available installation packages inquiry",
            cwd: "/sessions/bold-inspiring-tesla",
            userSelectedFolders: ["/Users/alice/code/app"],
            model: "claude-opus-4-5-20251101",
            createdAt: Date(timeIntervalSinceNow: -3600),
            lastActivityAt: Date(timeIntervalSinceNow: -60),
            isArchived: isArchived,
            sessionType: sessionType
        )
    }

    private func audit(_ lines: [String]) -> CoworkAuditState {
        var state = CoworkAuditState()
        state.apply(lines.map { CoworkAuditParser.event(fromLine: Data($0.utf8)) })
        return state
    }

    private func update(
        metadata: CoworkSessionMetadata? = nil,
        audit: CoworkAuditState = CoworkAuditState(),
        transcriptPath: String? = nil,
        lastActivity: Date? = nil,
        isLive: Bool = true,
        promptsStarted: Int = 0,
        turnsCompleted: Int = 0,
        permissionsRequested: Int = 0
    ) -> CoworkSessionWatcher.SessionUpdate {
        let metadata = metadata ?? self.metadata()
        return CoworkSessionWatcher.SessionUpdate(
            sessionId: metadata.sessionId,
            metadata: metadata,
            audit: audit,
            transcriptPath: transcriptPath,
            lastActivity: lastActivity,
            isLive: isLive,
            promptsStarted: promptsStarted,
            turnsCompleted: turnsCompleted,
            permissionsRequested: permissionsRequested
        )
    }

    // MARK: - Card identity

    func testLivePromptOpensAClaudeDesktopHostedClaudeCard() throws {
        let appState = AppState()
        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt]),
            promptsStarted: 1
        ))

        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.source, "claude", "same engine, same mascot — no new source")
        XCTAssertEqual(card.termBundleId, "com.anthropic.claudefordesktop")
        XCTAssertTrue(card.isNativeAppMode)
        XCTAssertEqual(card.terminalName, "Claude")
        XCTAssertEqual(card.status, .processing)
        XCTAssertEqual(card.sessionTitle, "Available installation packages inquiry")
        XCTAssertEqual(card.cwd, "/Users/alice/code/app")
        XCTAssertEqual(card.model, "claude-opus-4-5-20251101")
        XCTAssertEqual(card.providerSessionId, cliSessionId)
        // No transcript yet: the audit prompt stands in for the chat line.
        XCTAssertEqual(card.lastUserPrompt, "list the installers")
        XCTAssertEqual(card.recentMessages.map(\.text), ["list the installers"])
    }

    func testConfiguredModelOnlySeedsTheLabel() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        XCTAssertEqual(appState.sessions[key]?.model, "claude-opus-4-5-20251101", "nothing better known yet")

        // The transcript tailer reports the model that answered, spelled its way.
        appState.sessions[key]?.model = "claude-opus-4-5"
        var resaved = metadata()
        resaved.title = "Renamed task"
        appState.applyCoworkUpdate(update(
            metadata: resaved,
            audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.assistantReply])
        ))
        XCTAssertEqual(appState.sessions[key]?.model, "claude-opus-4-5")
        appState.applyCoworkUpdate(update(metadata: resaved, isLive: false))
        XCTAssertEqual(appState.sessions[key]?.model, "claude-opus-4-5", "a metadata save does not flip it back")
    }

    func testTranscriptModelWinsOnAttach() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("\(cliSessionId).jsonl").path
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"list the installers"}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","role":"assistant","content":[{"type":"text","text":"On it"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt]), transcriptPath: transcript))
        XCTAssertEqual(appState.sessions[key]?.model, "claude-sonnet-4-5")
        appState.removeSession(key)
    }

    func testKeysStayInTheirOwnNamespace() {
        XCTAssertEqual(AppState.coworkSessionKey(storeId), "cowork:\(storeId)")
        XCTAssertEqual(AppState.coworkStoreSessionId(fromKey: key), storeId)
        XCTAssertNil(AppState.coworkStoreSessionId(fromKey: cliSessionId))
        // Only the negative path: a positive call would open Claude Desktop.
        XCTAssertFalse(AppState.openCoworkSession(sessionKey: cliSessionId))
    }

    func testRunningToolIsShownWithSandboxPathsStripped() throws {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([
            CoworkAuditFixture.userPrompt,
            CoworkAuditFixture.assistantToolUse,
        ])))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .running)
        XCTAssertEqual(card.currentTool, "Bash")
        XCTAssertEqual(card.toolDescription, #"find alice -name "*.dmg""#)
    }

    // MARK: - Waiting (display-only)

    func testPermissionCardShowsAsDisplayOnlyWait() throws {
        let appState = AppState()
        let request = CoworkAuditFixture.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"rm x"}"#)
        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt, request]),
            permissionsRequested: 1
        ))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .waitingApproval)
        XCTAssertEqual(card.currentTool, "Bash")
        XCTAssertEqual(card.toolDescription, "Approve Bash in Claude Desktop · rm x")
        XCTAssertTrue(appState.permissionQueue.isEmpty, "nothing to answer from the island")
    }

    func testQuestionShowsTheQuestionText() throws {
        let appState = AppState()
        let question = CoworkAuditFixture.permissionRequest(
            id: "q", tool: "AskUserQuestion", input: #"{"questions":[{"question":"Which folder?"}]}"#
        )
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt, question])))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .waitingQuestion)
        XCTAssertEqual(card.toolDescription, "Answer in Claude Desktop: Which folder?")
        XCTAssertTrue(appState.questionQueue.isEmpty)
    }

    // MARK: - Completion

    func testCompletedTurnGoesIdleAndKeepsTheReply() throws {
        let appState = AppState()
        appState.applyCoworkUpdate(update(
            audit: audit([
                CoworkAuditFixture.userPrompt,
                CoworkAuditFixture.assistantReply,
                CoworkAuditFixture.resultSuccess,
            ]),
            promptsStarted: 1,
            turnsCompleted: 1
        ))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .idle)
        XCTAssertNil(card.currentTool)
        XCTAssertEqual(card.lastAssistantMessage, "Found a.dmg")
        XCTAssertEqual(card.recentMessages.map(\.isUser), [true, false])
    }

    func testAttachedTranscriptOwnsTheChatLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("\(cliSessionId).jsonl").path
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"list the installers"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"From the transcript"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.resultSuccess]),
            transcriptPath: transcript,
            turnsCompleted: 1
        ))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.transcriptPath, transcript)
        XCTAssertEqual(card.recentMessages.map(\.text), ["list the installers", "From the transcript"])
        XCTAssertEqual(appState.attachedTranscriptPaths[key], transcript)
        appState.removeSession(key)
    }

    // MARK: - Ghost cards

    func testHistoryNeverOpensACard() {
        let appState = AppState()
        // A title generated (or the file re-saved) for a session whose card the
        // idle sweep already collected.
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.resultSuccess]), isLive: false))
        XCTAssertNil(appState.sessions[key])
    }

    func testMetadataRefreshStillUpdatesAnExistingCard() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        var renamed = metadata()
        renamed.title = "Renamed task"
        appState.applyCoworkUpdate(update(metadata: renamed, audit: audit([CoworkAuditFixture.userPrompt]), isLive: false))
        XCTAssertEqual(appState.sessions[key]?.sessionTitle, "Renamed task")
    }

    func testArchivingRemovesTheCard() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        XCTAssertNotNil(appState.sessions[key])
        appState.applyCoworkUpdate(update(metadata: metadata(isArchived: true), isLive: false))
        XCTAssertNil(appState.sessions[key])
    }

    func testHiddenSessionTypesNeverGetACard() {
        let appState = AppState()
        for type in ["agent", "dispatch_child", "radar"] {
            appState.applyCoworkUpdate(update(
                metadata: metadata(sessionType: type),
                audit: audit([CoworkAuditFixture.userPrompt])
            ))
            XCTAssertNil(appState.sessions[key], type)
        }
        appState.applyCoworkUpdate(update(
            metadata: metadata(sessionType: "chat"),
            audit: audit([CoworkAuditFixture.userPrompt])
        ))
        XCTAssertNotNil(appState.sessions[key], "local Chat sessions are shown like Cowork tasks")
    }

    func testCoworkCardsAreNotWrittenToSessionsJSON() throws {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.resultSuccess])))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertNotNil(card.lastUserPrompt, "what an older build would restore as a ghost Claude card")
        XCTAssertFalse(SessionPersistence.isPersisted(sessionId: key, session: card))

        // A hook-driven Claude Code session — even one hosted by Claude
        // Desktop — is still saved.
        XCTAssertTrue(SessionPersistence.isPersisted(sessionId: cliSessionId, session: card))
        var remote = SessionSnapshot()
        remote.remoteHostId = "devbox"
        XCTAssertFalse(SessionPersistence.isPersisted(sessionId: "remote-1", session: remote))
    }

    func testLaunchSnapshotReplacesRestoredCards() throws {
        let appState = AppState()
        // What SessionPersistence restored from the previous run.
        let ghostKey = AppState.coworkSessionKey("local_0ld5e551-0000-0000-0000-000000000000")
        var ghost = SessionSnapshot()
        ghost.source = "claude"
        ghost.lastUserPrompt = "something from yesterday"
        appState.sessions[ghostKey] = ghost
        appState.sessions["unrelated-hook-session"] = SessionSnapshot()

        let lastActivity = Date(timeIntervalSinceNow: -120)
        appState.applyCoworkLaunchSnapshot([
            update(
                audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.resultSuccess]),
                lastActivity: lastActivity,
                isLive: false
            ),
        ], claudeDesktopRunning: true)

        XCTAssertNil(appState.sessions[ghostKey], "the store no longer vouches for it")
        XCTAssertNotNil(appState.sessions["unrelated-hook-session"])
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .idle)
        XCTAssertEqual(card.lastActivity, lastActivity, "keeps its real age for the idle sweep")
    }

    func testTurnOrphanedByAClaudeDesktopRestartIsRebuiltIdle() throws {
        let appState = AppState()
        let request = CoworkAuditFixture.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"rm x"}"#)
        let openCard = audit([CoworkAuditFixture.userPrompt, request])
        let launchedAt = Date(timeIntervalSinceNow: -30)

        // Last written before the running instance started: the card died with it.
        appState.applyCoworkLaunchSnapshot(
            [update(audit: openCard, lastActivity: launchedAt.addingTimeInterval(-60), isLive: false)],
            claudeDesktopRunning: true,
            claudeDesktopLaunchedAt: launchedAt
        )
        XCTAssertEqual(try XCTUnwrap(appState.sessions[key]).status, .idle)

        // Written by the running instance: genuinely still waiting.
        appState.sessions.removeAll()
        appState.applyCoworkLaunchSnapshot(
            [update(audit: openCard, lastActivity: Date(), isLive: false)],
            claudeDesktopRunning: true,
            claudeDesktopLaunchedAt: launchedAt
        )
        XCTAssertEqual(try XCTUnwrap(appState.sessions[key]).status, .waitingApproval)
    }

    func testMetadataUpdateNeverRevivesAWaitSettledAtLaunch() throws {
        let appState = AppState()
        let request = CoworkAuditFixture.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"rm x"}"#)
        let openCard = audit([CoworkAuditFixture.userPrompt, request])
        let launchedAt = Date(timeIntervalSinceNow: -30)
        appState.applyCoworkLaunchSnapshot(
            [update(audit: openCard, lastActivity: launchedAt.addingTimeInterval(-60), isLive: false)],
            claudeDesktopRunning: true,
            claudeDesktopLaunchedAt: launchedAt
        )
        XCTAssertEqual(try XCTUnwrap(appState.sessions[key]).status, .idle)

        // A generated title (or a model switch) re-saves the metadata. The
        // watcher's folded audit still holds the card that died with the old
        // Claude Desktop, and the update carries it along.
        var renamed = metadata()
        renamed.title = "Renamed task"
        appState.applyCoworkUpdate(update(metadata: renamed, audit: openCard, isLive: false))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.sessionTitle, "Renamed task", "metadata still applies")
        XCTAssertEqual(card.status, .idle, "only audit activity moves the turn state")
        XCTAssertTrue(appState.displayOnlyWaitingSessionIds(kind: .approval).isEmpty)
    }

    // MARK: - Settling what Claude Desktop will never finish

    /// A process identity that `isLiveProcess` accepts: this test process.
    private var liveHost: ProcessIdentity { ProcessIdentity(pid: getpid(), startTime: nil) }
    /// Same pid, another start time: the process that owned it is gone, as
    /// after a Claude Desktop restart.
    private var goneHost: ProcessIdentity { ProcessIdentity(pid: getpid(), startTime: .distantPast) }

    private func waitingCard(in appState: AppState) {
        let request = CoworkAuditFixture.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"rm x"}"#)
        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt, request]),
            permissionsRequested: 1
        ))
        XCTAssertEqual(appState.sessions[key]?.status, .waitingApproval)
    }

    func testSilenceTimeoutsForCoworkCards() {
        XCTAssertNil(AppState.coworkSilenceTimeout(status: .idle))
        // A long build writes nothing to the store for as long as it runs.
        XCTAssertEqual(AppState.coworkSilenceTimeout(status: .running), 30 * 60)
        XCTAssertEqual(AppState.coworkSilenceTimeout(status: .processing), 30 * 60)
        // A card left open is silent too; hours bound one nothing will close.
        XCTAssertEqual(AppState.coworkSilenceTimeout(status: .waitingApproval), 4 * 60 * 60)
        XCTAssertEqual(AppState.coworkSilenceTimeout(status: .waitingQuestion), 4 * 60 * 60)
    }

    func testLongRunningToolOutlivesTheGenericTimeout() throws {
        let appState = AppState()
        appState.claudeDesktopProcessProvider = { self.liveHost }
        appState.applyCoworkUpdate(update(audit: audit([
            CoworkAuditFixture.userPrompt,
            CoworkAuditFixture.assistantToolUse,
        ])))
        let started = try XCTUnwrap(appState.sessions[key]).lastActivity

        // Well past the 3-minute rule for a quiet tool.
        appState.settleCoworkCards(now: started.addingTimeInterval(20 * 60))
        XCTAssertEqual(appState.sessions[key]?.status, .running)
        XCTAssertEqual(appState.sessions[key]?.currentTool, "Bash")

        appState.settleCoworkCards(now: started.addingTimeInterval(31 * 60))
        XCTAssertEqual(appState.sessions[key]?.status, .idle)
        XCTAssertNil(appState.sessions[key]?.currentTool)
    }

    func testAnOpenPermissionCardIsSettledAfterHoursOfSilence() throws {
        let appState = AppState()
        appState.claudeDesktopProcessProvider = { self.liveHost }
        waitingCard(in: appState)
        let asked = try XCTUnwrap(appState.sessions[key]).lastActivity

        appState.settleCoworkCards(now: asked.addingTimeInterval(3 * 60 * 60))
        XCTAssertEqual(appState.sessions[key]?.status, .waitingApproval, "still plausibly waiting")

        appState.settleCoworkCards(now: asked.addingTimeInterval(4 * 60 * 60 + 1))
        XCTAssertEqual(appState.sessions[key]?.status, .idle)
        XCTAssertTrue(appState.displayOnlyWaitingSessionIds(kind: .approval).isEmpty)
    }

    func testWaitDiesWithTheClaudeDesktopProcessItWasAskedIn() throws {
        let appState = AppState()
        appState.followUps.armsTimer = false
        appState.followUps.intervalProvider = { 60 }
        appState.claudeDesktopProcessProvider = { self.liveHost }
        waitingCard(in: appState)
        XCTAssertEqual(appState.coworkTurnHosts[key], liveHost)
        let reminder = FollowUpReminderScheduler.Key(.approval, key)
        XCTAssertNotNil(appState.followUps.scheduler.origin(of: reminder))

        appState.settleCoworkCards()
        XCTAssertEqual(appState.sessions[key]?.status, .waitingApproval, "its Claude Desktop still runs")

        // Claude Desktop restarted between two sweeps (an auto-update): the
        // process the card was asked in is gone, whatever runs now.
        appState.coworkTurnHosts[key] = goneHost
        appState.settleCoworkCards()
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .idle)
        XCTAssertNil(card.currentTool)
        XCTAssertNil(appState.coworkTurnHosts[key])
        XCTAssertTrue(appState.displayOnlyWaitingSessionIds(kind: .approval).isEmpty)
        XCTAssertNil(appState.followUps.scheduler.origin(of: reminder), "no more reminders")
    }

    func testTurnHostIsForgottenOnceTheTurnEnds() {
        let appState = AppState()
        appState.claudeDesktopProcessProvider = { self.liveHost }
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        XCTAssertEqual(appState.coworkTurnHosts[key], liveHost)

        // A new host is only taken when a turn starts, not on every update.
        appState.claudeDesktopProcessProvider = { self.goneHost }
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.assistantReply])))
        XCTAssertEqual(appState.coworkTurnHosts[key], liveHost)

        appState.applyCoworkUpdate(update(
            audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.resultSuccess]),
            turnsCompleted: 1
        ))
        XCTAssertNil(appState.coworkTurnHosts[key])
    }

    func testQuittingClaudeDesktopSettlesEveryOpenCoworkTurn() throws {
        let appState = AppState()
        appState.claudeDesktopProcessProvider = { self.liveHost }
        waitingCard(in: appState)
        let otherKey = AppState.coworkSessionKey("local_0ther000-0000-0000-0000-000000000000")
        appState.applyCoworkUpdate(update(
            metadata: metadata(storeId: "local_0ther000-0000-0000-0000-000000000000"),
            audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.assistantToolUse])
        ))
        var hook = SessionSnapshot()
        hook.status = .processing
        appState.sessions["hook-session"] = hook

        appState.claudeDesktopTerminated()
        XCTAssertEqual(appState.sessions[key]?.status, .idle)
        XCTAssertEqual(appState.sessions[otherKey]?.status, .idle)
        XCTAssertEqual(appState.sessions["hook-session"]?.status, .processing, "not Claude Desktop's")
        XCTAssertTrue(appState.coworkTurnHosts.isEmpty)
        XCTAssertTrue(appState.displayOnlyWaitingSessionIds(kind: .approval).isEmpty)
    }

    func testLaunchSnapshotShowsNothingWhileClaudeDesktopIsClosed() {
        let appState = AppState()
        appState.sessions[key] = SessionSnapshot()
        appState.applyCoworkLaunchSnapshot([
            update(audit: audit([CoworkAuditFixture.userPrompt]), lastActivity: Date(), isLive: false),
        ], claudeDesktopRunning: false)
        XCTAssertTrue(appState.sessions.isEmpty)
    }

    // MARK: - Duplicates

    func testHookDrivenCardWins() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        XCTAssertNotNil(appState.sessions[key])

        // Hooks start arriving for the same conversation (keyed by CLI session id).
        appState.sessions[cliSessionId] = SessionSnapshot()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt, CoworkAuditFixture.assistantReply])))
        XCTAssertNil(appState.sessions[key])
        XCTAssertNotNil(appState.sessions[cliSessionId])
    }

    func testStoppingRemovesEveryCoworkCard() {
        let appState = AppState()
        appState.applyCoworkUpdate(update(audit: audit([CoworkAuditFixture.userPrompt])))
        appState.sessions["hook"] = SessionSnapshot()
        appState.removeCoworkSessions()
        XCTAssertNil(appState.sessions[key])
        XCTAssertNotNil(appState.sessions["hook"])
    }
}

/// What a Cowork turn end sets off — sound, completion, follow-up — with the
/// sound sink and the follow-up clock taken over.
@MainActor
final class AppStateCoworkTurnEndTests: XCTestCase {
    private let storeId = "local_5b0e2c71-turn-end"
    private var key: String { AppState.coworkSessionKey(storeId) }
    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundTaskError,
        SettingsKey.soundTaskComplete,
        SettingsKey.quietHoursEnabled,
        SettingsKey.completionNotificationStyle,
    ]

    override func setUp() {
        super.setUp()
        L10n.shared.language = "en"
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in self?.played.append(name) }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskError)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskComplete)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        // Glance: a queued completion lights the dot instead of opening a
        // card, which needs no window.
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        L10n.shared.language = "system"
        super.tearDown()
    }

    private func appState() -> AppState {
        let appState = AppState()
        appState.followUps.armsTimer = false
        appState.followUps.intervalProvider = { 60 }
        return appState
    }

    /// A live turn that started and ended in one batch, ending with `result`.
    private func turn(endingWith result: String) -> CoworkSessionWatcher.SessionUpdate {
        let metadata = CoworkSessionMetadata(
            sessionId: storeId,
            cliSessionId: "cli-turn-end",
            title: "Installer inventory",
            userSelectedFolders: ["/Users/alice/code/app"],
            createdAt: Date(timeIntervalSinceNow: -3600)
        )
        var audit = CoworkAuditState()
        audit.apply([CoworkAuditFixture.userPrompt, CoworkAuditFixture.assistantToolUse, result]
            .map { CoworkAuditParser.event(fromLine: Data($0.utf8)) })
        return CoworkSessionWatcher.SessionUpdate(
            sessionId: storeId,
            metadata: metadata,
            audit: audit,
            transcriptPath: nil,
            lastActivity: nil,
            isLive: true,
            promptsStarted: 1,
            turnsCompleted: 1,
            permissionsRequested: 0
        )
    }

    private func tracksCompletionFollowUp(_ appState: AppState) -> Bool {
        appState.followUps.scheduler.origin(of: FollowUpReminderScheduler.Key(.completion, key)) != nil
    }

    func testStopInClaudeDesktopReadsInterruptedAndStaysQuiet() throws {
        let appState = appState()
        appState.applyCoworkUpdate(turn(endingWith: CoworkAuditFixture.resultStopped))

        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .idle)
        XCTAssertTrue(card.interrupted)
        XCTAssertNil(card.currentTool)
        XCTAssertEqual(card.lastAssistantMessage, "Reply interrupted")
        XCTAssertEqual(played, [], "no error jingle, no completion jingle")
        XCTAssertFalse(appState.glanceCompletionActive, "not queued as a completion")
        XCTAssertFalse(tracksCompletionFollowUp(appState), "nothing to follow up")
    }

    func testFailedTurnStillRingsAndQueues() throws {
        let appState = appState()
        appState.applyCoworkUpdate(turn(endingWith: CoworkAuditFixture.resultFailed))

        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .idle)
        XCTAssertFalse(card.interrupted)
        XCTAssertEqual(card.lastAssistantMessage, L10n.shared["reply_failed_placeholder"])
        XCTAssertEqual(played, ["8bit_error"])
        XCTAssertTrue(appState.glanceCompletionActive)
        XCTAssertTrue(tracksCompletionFollowUp(appState))
    }

    func testNextPromptClearsTheInterruptedMark() throws {
        let appState = appState()
        appState.applyCoworkUpdate(turn(endingWith: CoworkAuditFixture.resultStopped))
        XCTAssertEqual(appState.sessions[key]?.interrupted, true)

        var next = turn(endingWith: CoworkAuditFixture.resultStopped).audit
        next.apply(CoworkAuditParser.event(fromLine: Data(CoworkAuditFixture.userPrompt.utf8)))
        appState.applyCoworkUpdate(CoworkSessionWatcher.SessionUpdate(
            sessionId: storeId,
            metadata: CoworkSessionMetadata(sessionId: storeId, cliSessionId: "cli-turn-end"),
            audit: next,
            transcriptPath: nil,
            lastActivity: nil,
            isLive: true,
            promptsStarted: 1,
            turnsCompleted: 0,
            permissionsRequested: 0
        ))
        let card = try XCTUnwrap(appState.sessions[key])
        XCTAssertEqual(card.status, .processing)
        XCTAssertFalse(card.interrupted)
    }
}

/// `audit.jsonl` lines in the real record shapes (the core suite's
/// CoworkAuditLogTests pins the parser against the same shapes).
enum CoworkAuditFixture {
    private static let ts = #""_audit_timestamp":"2026-01-13T10:39:52.333Z""#

    static let userPrompt = #"{"type":"user","uuid":"u1","session_id":"f421","parent_tool_use_id":null,"message":{"role":"user","content":"list the installers"},"# + ts + "}"
    static let assistantToolUse = #"{"type":"assistant","message":{"model":"claude-opus-4-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"find /sessions/bold-inspiring-tesla/mnt/alice -name \"*.dmg\""}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"a2","# + ts + "}"
    static let assistantReply = #"{"type":"assistant","message":{"model":"claude-opus-4-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Found a.dmg"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"a3","# + ts + "}"
    static let resultSuccess = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":50948,"num_turns":2,"result":"Found a.dmg","session_id":"d0a5","total_cost_usd":0.24,"permission_denials":[],"uuid":"r1","# + ts + "}"
    static let resultFailed = #"{"type":"result","subtype":"error_during_execution","duration_ms":3000,"is_error":true,"num_turns":1,"stop_reason":null,"session_id":"d0a5","permission_denials":[],"terminal_reason":"api_error","errors":["overloaded"],"uuid":"r4","# + ts + "}"
    /// Claude Desktop's Stop button, as the CLI reports it.
    static let resultStopped = #"{"type":"result","subtype":"error_during_execution","duration_ms":8123,"is_error":true,"num_turns":1,"stop_reason":null,"session_id":"d0a5","permission_denials":[],"terminal_reason":"aborted_streaming","errors":["stopped"],"uuid":"r2","# + ts + "}"

    static func permissionRequest(id: String, tool: String, input: String) -> String {
        #"{"type":"system","subtype":"permission_request","uuid":""# + id + #"","session_id":"d0a5","tool_name":""# + tool + #"","tool_input":"# + input + "," + ts + "}"
    }
}
