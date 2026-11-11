import XCTest
@testable import CodeIsland
@testable import CodeIslandCore
import Darwin

/// #318: `/resume` inside a running Grok TUI loads another session into the
/// same process. The previous card must not linger, and discovery must not
/// rewrite it into a second card for the resumed session.
@MainActor
final class AppStateGrokSessionSwitchTests: XCTestCase {
    // Identifiers and cwd from the reporter's persisted-sessions.json.
    private let cwd = "/Users/a123/git_file/test_project"
    private let previousId = "01a0226f-1be5-7591-9031-cab500723788"
    private let resumedId = "01a05ffe-e470-76b1-b227-cedb9ae65aea"
    private var savedSmartSuppress: Any?

    /// These hooks name Ghostty as the terminal, and every `Stop` shows a
    /// completion. With Smart Suppress on (its default) that asks the real
    /// terminal-visibility probe, which — whenever Ghostty happens to be the
    /// frontmost app on the machine running the tests — scripts System Events
    /// from a background thread. Nothing here is about suppression, so keep
    /// the outcome independent of the desktop.
    override func setUp() {
        super.setUp()
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        if let savedSmartSuppress {
            UserDefaults.standard.set(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress)
        }
        super.tearDown()
    }

    private func transcriptPath(_ sessionId: String) -> String {
        "/Users/a123/.grok/sessions/%2FUsers%2Fa123%2Fgit_file%2Ftest_project/\(sessionId)/chat_history.jsonl"
    }

    /// A Grok hook as the bridge forwards it: `--source grok`, the Grok TUI
    /// as `_ppid`, and the synthesized chat-history transcript path.
    private func grokHook(
        _ eventName: String,
        sessionId: String,
        pid: pid_t = getpid(),
        extra: [String: Any] = [:]
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": eventName,
            "session_id": sessionId,
            "cwd": cwd,
            "_source": "grok",
            "_ppid": Int(pid),
            "_term_app": "ghostty",
            "transcript_path": transcriptPath(sessionId),
        ]
        payload.merge(extra) { _, new in new }
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private func startIdleGrokSession(_ appState: AppState, _ sessionId: String) throws {
        appState.handleEvent(try grokHook("SessionStart", sessionId: sessionId))
        appState.handleEvent(try grokHook("UserPromptSubmit", sessionId: sessionId, extra: ["prompt": "hello"]))
        appState.handleEvent(try grokHook("Stop", sessionId: sessionId, extra: ["last_assistant_message": "Hi!"]))
        XCTAssertEqual(appState.sessions[sessionId]?.status, .idle)
    }

    private func resumedDiscovery(modifiedAt: Date = Date()) -> DiscoveredSession {
        GrokDiscovery.grokDiscoveredSession(
            sessionId: resumedId,
            cwd: cwd,
            model: "grok-4.6",
            pid: getpid(),
            modifiedAt: modifiedAt,
            recentMessages: [ChatMessage(isUser: true, text: "<user_query>\nhello\n</user_query>")],
            transcriptPath: transcriptPath(resumedId)
        )
    }

    private func assertProviderSessionIdsAreUnique(
        _ appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ids = appState.sessions.values.compactMap(\.providerSessionId)
        XCTAssertEqual(ids.count, Set(ids).count, "two cards share a providerSessionId: \(ids)", file: file, line: line)
    }

    func testGrokDiscoveryCarriesItsSessionIdAsProviderId() {
        XCTAssertEqual(resumedDiscovery().providerSessionId, resumedId)
        XCTAssertEqual(resumedDiscovery().source, "grok")
    }

    /// Replays the reported order: the resumed session's files change (and a
    /// discovery scan runs) before its SessionStart hook lands.
    func testResumeInSameProcessKeepsOneCardAndNeverRewritesThePreviousOne() throws {
        let appState = AppState()
        try startIdleGrokSession(appState, previousId)

        appState.integrateDiscovered([resumedDiscovery()])

        let previous = try XCTUnwrap(appState.sessions[previousId])
        XCTAssertNotEqual(previous.providerSessionId, resumedId)
        XCTAssertEqual(previous.transcriptPath, transcriptPath(previousId))
        XCTAssertEqual(previous.lastUserPrompt, "hello")
        XCTAssertNotNil(appState.sessions[resumedId], "the resumed session gets its own card")
        assertProviderSessionIdsAreUnique(appState)

        appState.handleEvent(try grokHook("SessionStart", sessionId: resumedId))

        XCTAssertEqual(Array(appState.sessions.keys), [resumedId])
        XCTAssertEqual(appState.sessions[resumedId]?.cliPid, getpid())
        assertProviderSessionIdsAreUnique(appState)
    }

    func testResumeWithHookBeforeDiscoveryRetiresPreviousAndStaysRetired() throws {
        let appState = AppState()
        try startIdleGrokSession(appState, previousId)

        appState.handleEvent(try grokHook("SessionStart", sessionId: resumedId))
        XCTAssertEqual(Array(appState.sessions.keys), [resumedId])

        // A later scan still maps the live TUI's PID to the previous session.
        appState.integrateDiscovered([GrokDiscovery.grokDiscoveredSession(
            sessionId: previousId,
            cwd: cwd,
            model: "grok-4.6",
            pid: getpid(),
            modifiedAt: Date(),
            recentMessages: [ChatMessage(isUser: true, text: "hello")],
            transcriptPath: transcriptPath(previousId)
        )])
        // Passive hooks the left session can still fire must not revive it.
        appState.handleEvent(try grokHook("Notification", sessionId: previousId, extra: [
            "notification_type": "idle_prompt",
            "message": "Grok is waiting for your input",
        ]))
        appState.handleEvent(try grokHook("Stop", sessionId: previousId, extra: ["reason": "channel_closed"]))

        XCTAssertEqual(Array(appState.sessions.keys), [resumedId])
    }

    func testSwitchingBackToTheRetiredSessionRevivesItAndRetiresTheOther() throws {
        let appState = AppState()
        try startIdleGrokSession(appState, previousId)
        appState.handleEvent(try grokHook("SessionStart", sessionId: resumedId))
        appState.handleEvent(try grokHook("UserPromptSubmit", sessionId: resumedId, extra: ["prompt": "continue"]))
        appState.handleEvent(try grokHook("Stop", sessionId: resumedId))

        appState.handleEvent(try grokHook("SessionStart", sessionId: previousId))

        XCTAssertEqual(Array(appState.sessions.keys), [previousId])
    }

    func testPromptInRetiredSessionRevivesItWithoutAnotherSessionStart() throws {
        let appState = AppState()
        try startIdleGrokSession(appState, previousId)
        appState.handleEvent(try grokHook("SessionStart", sessionId: resumedId))

        appState.handleEvent(try grokHook("UserPromptSubmit", sessionId: previousId, extra: ["prompt": "back again"]))

        XCTAssertEqual(appState.sessions[previousId]?.status, .processing)
        XCTAssertNotNil(appState.sessions[resumedId])
    }

    /// The Agent Dashboard runs several top-level sessions in one pager
    /// process; starting another must not hide one that is still working.
    func testSessionStartKeepsSameProcessGrokSessionThatIsStillWorking() throws {
        let appState = AppState()
        appState.handleEvent(try grokHook("SessionStart", sessionId: previousId))
        appState.handleEvent(try grokHook("UserPromptSubmit", sessionId: previousId, extra: ["prompt": "run the tests"]))

        appState.handleEvent(try grokHook("SessionStart", sessionId: resumedId))

        XCTAssertEqual(Set(appState.sessions.keys), [previousId, resumedId])
        XCTAssertEqual(appState.sessions[previousId]?.status, .processing)
    }

    func testSessionStartOnlyRetiresSessionsOfTheSameProcess() throws {
        let appState = AppState()
        try startIdleGrokSession(appState, previousId)
        let otherTUI = getppid()

        appState.handleEvent(try grokHook("SessionStart", sessionId: resumedId, pid: otherTUI))

        XCTAssertEqual(Set(appState.sessions.keys), [previousId, resumedId])
    }

    func testSessionStartDoesNotRetireOtherProvidersSharingAPid() throws {
        let appState = AppState()
        func claudeHook(_ eventName: String, _ sessionId: String) throws -> HookEvent {
            try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
                "hook_event_name": eventName,
                "session_id": sessionId,
                "cwd": cwd,
                "_source": "claude",
                "_ppid": Int(getpid()),
            ])))
        }
        appState.handleEvent(try claudeHook("SessionStart", "claude-one"))
        appState.handleEvent(try claudeHook("Stop", "claude-one"))

        appState.handleEvent(try claudeHook("SessionStart", "claude-two"))

        XCTAssertEqual(Set(appState.sessions.keys), ["claude-one", "claude-two"])
    }

    func testSupersededPredicateRequiresAnIdleSameProcessGrokCard() {
        var started = SessionSnapshot()
        started.source = "grok"
        started.cliPid = 4242
        var candidate = started

        XCTAssertTrue(AppState.isGrokSessionSupersededBySessionStart(
            candidate: candidate, candidateId: "old", started: started, startedId: "new"
        ))
        XCTAssertFalse(AppState.isGrokSessionSupersededBySessionStart(
            candidate: candidate, candidateId: "new", started: started, startedId: "new"
        ), "a SessionStart never retires its own card")

        var busy = candidate
        busy.status = .waitingApproval
        XCTAssertFalse(AppState.isGrokSessionSupersededBySessionStart(
            candidate: busy, candidateId: "old", started: started, startedId: "new"
        ))

        var withWorkingSubagent = candidate
        var subagent = SubagentState(agentId: "explore-1", agentType: "explore")
        subagent.status = .running
        withWorkingSubagent.subagents["explore-1"] = subagent
        XCTAssertFalse(AppState.isGrokSessionSupersededBySessionStart(
            candidate: withWorkingSubagent, candidateId: "old", started: started, startedId: "new"
        ))

        var remote = candidate
        remote.remoteHostId = "devbox"
        XCTAssertFalse(AppState.isGrokSessionSupersededBySessionStart(
            candidate: remote, candidateId: "old", started: started, startedId: "new"
        ))

        for source in ["codex", "claude", "opencode", "cursor"] {
            var other = started
            other.source = source
            XCTAssertFalse(AppState.isGrokSessionSupersededBySessionStart(
                candidate: other, candidateId: "old", started: other, startedId: "new"
            ), source)
        }

        candidate.cliPid = nil
        XCTAssertFalse(AppState.isGrokSessionSupersededBySessionStart(
            candidate: candidate, candidateId: "old", started: started, startedId: "new"
        ))
    }
}
