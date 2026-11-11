import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A remote session's hooks name things on its own host: a process id, a
/// transcript file, a terminal tab. None of them may drive anything on this
/// Mac — not a process watch (or the SIGTERM of orphan cleanup), not a file
/// read that would put this Mac's content on the remote card, not a query to
/// this Mac's terminals.
@MainActor
final class RemoteSessionIsolationTests: XCTestCase {
    private var root: URL!
    private var savedProbe: TerminalVisibilityDetector.Probe!
    private var savedPluginSessionMode: Any?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedProbe = TerminalVisibilityDetector.probe
        savedPluginSessionMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
    }

    override func tearDownWithError() throws {
        TerminalVisibilityDetector.probe = savedProbe
        if let savedPluginSessionMode {
            UserDefaults.standard.set(savedPluginSessionMode, forKey: SettingsKey.pluginSessionMode)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func event(_ fields: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: fields)))
    }

    /// A Claude transcript on this Mac, at the path a remote hook names.
    private func localTranscript() throws -> URL {
        let url = root.appendingPathComponent("transcript.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"THIS MAC'S PROMPT"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"local-model","content":[{"type":"text","text":"THIS MAC'S REPLY"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Processes

    /// The card a remote subagent's request created looked local, so its
    /// `_ppid` — here, this very test process — was watched as the card's CLI.
    func testRemoteRequestNeverWatchesALocalProcess() async throws {
        let appState = AppState()
        let request = try event([
            "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/home/me/project",
            "_source": "claude", "_remote_host_id": "devbox", "_ppid": Int(getpid()),
            "agent_id": "sub-1", "agent_type": "general-purpose",
            "tool_name": "Bash", "tool_input": ["command": "make"],
        ])

        let task = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        let card = try XCTUnwrap(appState.sessions["remote:devbox:s1"])
        XCTAssertTrue(card.isRemote)
        XCTAssertNil(card.cliPid, "no process here is the remote CLI")
        XCTAssertNil(card.cliStartTime)

        appState.denyPermission(expectedSessionId: "remote:devbox:s1")
        _ = try await awaitValue(of: task)
    }

    func testRemoteHookEventNeverWatchesALocalProcess() throws {
        let appState = AppState()
        for fields in [[:], ["agent_id": "sub-1", "agent_type": "general-purpose"]] as [[String: Any]] {
            var payload: [String: Any] = [
                "hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/home/me/project",
                "_source": "claude", "_remote_host_id": "devbox", "_ppid": Int(getpid()), "tool_name": "Bash",
            ]
            payload.merge(fields) { _, new in new }
            appState.handleEvent(try event(payload))

            XCTAssertNil(appState.sessions["remote:devbox:s1"]?.cliPid, "\(fields)")
        }
    }

    // MARK: - Files

    /// A remote transcript path names a file on its own host. Read here, a
    /// file at the same path put this Mac's prompt and reply on the card.
    func testRemoteTranscriptPathIsNeverReadHere() throws {
        let transcript = try localTranscript()
        let appState = AppState()
        let hooks: [[String: Any]] = [
            ["agent_id": "sub-1", "agent_type": "general-purpose"],  // creates the card
            [:],
        ]
        for fields in hooks {
            var payload: [String: Any] = [
                "hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/home/me/project",
                "_source": "claude", "_remote_host_id": "devbox", "tool_name": "Bash",
                "transcript_path": transcript.path,
            ]
            payload.merge(fields) { _, new in new }
            appState.handleEvent(try event(payload))

            let card = try XCTUnwrap(appState.sessions["remote:devbox:s1"])
            XCTAssertNil(appState.attachedTranscriptPaths["remote:devbox:s1"], "\(fields)")
            XCTAssertFalse(card.recentMessages.contains { $0.text.contains("THIS MAC'S") }, "\(fields)")
            XCTAssertFalse(appState.modelReadsInFlight.contains("remote:devbox:s1"),
                           "no store or transcript read for its model, \(fields)")
        }

        appState.attachTranscriptTailerIfNeeded(sessionId: "remote:devbox:s1")
        XCTAssertNil(appState.attachedTranscriptPaths["remote:devbox:s1"])
    }

    /// Cursor's fold made the chat card of a remote Task that arrived first —
    /// as a local card, then tailed the remote transcript path here.
    func testCursorFoldKeepsARemoteTasksChatOnItsHost() throws {
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        let transcriptPath = "/home/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"

        let appState = AppState()
        var task = SessionSnapshot()
        task.source = "cursor"
        task.status = .running
        task.currentTool = "Read"
        task.providerSessionId = childId
        task.transcriptPath = transcriptPath
        task.remoteHostId = "devbox"
        appState.sessions["remote:devbox:\(childId)"] = task

        XCTAssertTrue(appState.applyCursorSubsessionModeToKnownSessions())

        let chat = try XCTUnwrap(appState.sessions.values.first { $0.providerSessionId == parentId })
        XCTAssertEqual(chat.remoteHostId, "devbox", "the chat is on the Task's host")
        XCTAssertTrue(appState.attachedTranscriptPaths.isEmpty, "\(appState.attachedTranscriptPaths)")
    }

    /// This Mac's rollouts know nothing of a remote thread. Read at the remote
    /// card's transcript path, a local rollout folded the remote card into a
    /// local session.
    func testCodexSweepNeverFoldsARemoteCardByALocalRollout() throws {
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        let rollout = root.appendingPathComponent("child.jsonl")
        try (#"{"type":"session_meta","payload":{"id":"child-thread","cwd":"/repo","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","agent_role":"worker"}}}}}"# + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.providerSessionId = "parent-thread"
        parent.status = .running
        var remote = SessionSnapshot()
        remote.source = "codex"
        remote.providerSessionId = "child-thread"
        remote.status = .running
        remote.transcriptPath = rollout.path
        remote.remoteHostId = "devbox"
        appState.sessions["parent"] = parent
        appState.sessions["remote:devbox:child-thread"] = remote

        _ = appState.applyCodexSubsessionModeToKnownSessions(statePath: root.appendingPathComponent("none.sqlite").path)

        XCTAssertNotNil(appState.sessions["remote:devbox:child-thread"], "still its own card")
        XCTAssertTrue(appState.sessions["parent"]?.subagents.isEmpty ?? false)
    }

    // MARK: - Terminals

    /// Smart Suppress, follow-up reminders and jump validation ask whether
    /// the session's tab is showing — by its terminal's bundle id, its tmux
    /// pane, its iTerm session, its pid. A remote session's are its own
    /// host's; asked here, they ran this Mac's terminal CLIs with the remote
    /// values and could answer "visible" about a tab on this Mac.
    func testTerminalVisibilityNeverAsksAboutARemoteSession() {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var checks: [String] = []
            var all: [String] { lock.lock(); defer { lock.unlock() }; return checks }
            func record(_ check: String) -> Bool {
                lock.lock(); checks.append(check); lock.unlock()
                return true
            }
        }
        let asked = Asked()
        TerminalVisibilityDetector.probe = TerminalVisibilityDetector.Probe(
            isTerminalFrontmost: { _ in asked.record("frontmost") },
            isSessionTabVisible: { _ in asked.record("tab") },
            isSessionLocatable: { _ in asked.record("locatable") }
        )
        var session = SessionSnapshot()
        session.termBundleId = "com.googlecode.iterm2"
        session.itermSessionId = "w0t0p0:REMOTE"
        session.tmuxPane = "%3"
        session.remotePid = 4242
        session.remoteHostId = "devbox"

        XCTAssertFalse(TerminalVisibilityDetector.isTerminalFrontmostForSession(session))
        XCTAssertFalse(TerminalVisibilityDetector.isSessionTabVisible(session))
        XCTAssertFalse(TerminalVisibilityDetector.didJumpLand(session))
        XCTAssertEqual(asked.all, [], "nothing on this Mac is asked about a remote session")

        session.remoteHostId = nil
        XCTAssertTrue(TerminalVisibilityDetector.isTerminalFrontmostForSession(session), "a local one still is")
    }
}
