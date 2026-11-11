import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Agent Sub-Sessions the same way for every kind of child session, end to
/// end: hooks go through HookServer's routing and then AppState, as in the
/// app. Show separately keeps a known child on a card of its own that never
/// rings or pops a completion card; a child stays where it is until it ends;
/// Hide never answers a request for the user.
@MainActor
final class SubsessionRoutingTests: XCTestCase {
    private let parentThread = "019a0000-0000-7000-8000-00000000000a"
    private let childThread = "019a0000-0000-7000-8000-00000000000b"
    private let cursorChat = "e1247fd5-d9a0-48ef-8457-0304606b1833"
    private let cursorTask = "2528cb91-6379-48f2-aff8-40f4b804dafa"
    private let otherChat = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]
    private var rolloutDir: URL!

    private let watchedKeys = [
        SettingsKey.pluginSessionMode,
        SettingsKey.soundEnabled,
        SettingsKey.soundSessionStart,
        SettingsKey.soundTaskComplete,
        SettingsKey.soundTaskError,
        SettingsKey.soundApprovalNeeded,
        SettingsKey.soundPromptSubmit,
        SettingsKey.quietHoursEnabled,
        SettingsKey.autoMuteWhenAway,
        SettingsKey.smartSuppress,
        SettingsKey.completionNotificationStyle,
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SettingsKey.soundEnabled)
        defaults.set(true, forKey: SettingsKey.soundSessionStart)
        defaults.set(true, forKey: SettingsKey.soundTaskComplete)
        defaults.set(true, forKey: SettingsKey.soundTaskError)
        defaults.set(true, forKey: SettingsKey.soundApprovalNeeded)
        defaults.set(false, forKey: SettingsKey.soundPromptSubmit)
        defaults.set(false, forKey: SettingsKey.quietHoursEnabled)
        defaults.set(false, forKey: SettingsKey.autoMuteWhenAway)
        defaults.set(false, forKey: SettingsKey.smartSuppress)
        defaults.set("expand", forKey: SettingsKey.completionNotificationStyle)
        defaults.set("separate", forKey: SettingsKey.pluginSessionMode)

        rolloutDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-subsession-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rolloutDir, withIntermediateDirectories: true)
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
        if let rolloutDir {
            try? FileManager.default.removeItem(at: rolloutDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func setMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: SettingsKey.pluginSessionMode)
    }

    private struct Routed {
        let raw: [String: Any]
        let data: Data
        let response: Data?
        var sessionId: String? { raw["session_id"] as? String }
    }

    private func route(_ payload: [String: Any], server: HookServer) throws -> Routed {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: routed.processedData) as? [String: Any])
        return Routed(raw: raw, data: routed.processedData, response: routed.responseData)
    }

    /// Route a non-blocking hook and hand it to AppState, as HookServer does.
    @discardableResult
    private func deliver(_ payload: [String: Any], to appState: AppState, server: HookServer) throws -> Routed {
        let routed = try route(payload, server: server)
        if routed.response == nil {
            appState.handleEvent(try XCTUnwrap(HookEvent(from: routed.data)))
        }
        return routed
    }

    private func writeRollout(_ name: String, sessionMeta: String) throws -> String {
        let url = rolloutDir.appendingPathComponent(name)
        try (sessionMeta + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func rootRollout(_ thread: String) -> String {
        #"{"type":"session_meta","payload":{"id":"\#(thread)","cwd":"/repo","source":"cli"}}"#
    }

    private func childRollout(_ thread: String, parent: String) -> String {
        #"{"type":"session_meta","payload":{"id":"\#(thread)","cwd":"/repo","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","agent_role":"worker","agent_nickname":"Ohm"}}}}}"#
    }

    /// A Codex state database that does not exist: the passes over known
    /// cards go by rollouts alone.
    private var missingStatePath: String {
        rolloutDir.appendingPathComponent("missing.sqlite").path
    }

    private func codex(_ event: String, thread: String, transcript: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        [
            "hook_event_name": event, "session_id": thread, "_source": "codex",
            "cwd": "/repo", "transcript_path": transcript,
        ].merging(extra) { _, new in new }
    }

    // MARK: - Codex: a child shown separately stays quiet

    /// A Codex subagent thread on a card of its own used to chime and pop a
    /// completion card for every turn, like the session the user started.
    func testCodexChildShownSeparatelyNeverRingsOrCompletes() throws {
        let parentPath = try writeRollout("parent.jsonl", sessionMeta: rootRollout(parentThread))
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        let appState = AppState()
        let server = HookServer(appState: appState)

        try deliver(codex("SessionStart", thread: parentThread, transcript: parentPath), to: appState, server: server)
        try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: parentPath, ["prompt": "fan out"]), to: appState, server: server)
        try deliver(codex("PreToolUse", thread: parentThread, transcript: parentPath, ["tool_name": "spawn_agent"]), to: appState, server: server)

        let start = try deliver(codex("SessionStart", thread: childThread, transcript: childPath), to: appState, server: server)
        XCTAssertEqual(start.sessionId, childThread, "kept on its own card")
        XCTAssertEqual(start.raw[SubsessionRouter.linkedParentKey] as? String, parentThread)
        try deliver(codex("UserPromptSubmit", thread: childThread, transcript: childPath, ["prompt": "task"]), to: appState, server: server)
        try deliver(codex("PreToolUse", thread: childThread, transcript: childPath, ["tool_name": "exec_command"]), to: appState, server: server)
        try deliver(codex("Stop", thread: childThread, transcript: childPath, ["last_assistant_message": "done"]), to: appState, server: server)

        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread)
        XCTAssertEqual(appState.sessions[childThread]?.status, .idle, "its card still settles")
        XCTAssertNil(appState.justCompletedSessionId, "a child's turn pops no completion card")
        XCTAssertEqual(played, ["8bit_start"], "the child neither starts nor finishes audibly")

        try deliver(codex("Stop", thread: parentThread, transcript: parentPath, ["last_assistant_message": "all done"]), to: appState, server: server)
        XCTAssertEqual(played, ["8bit_start", "8bit_complete"], "the parent chimes exactly once")
        XCTAssertEqual(appState.justCompletedSessionId, parentThread)
        XCTAssertNil(appState.sessions[parentThread]?.parentSessionId)
    }

    /// The rollout is read once per thread: the router asks on every hook.
    func testCodexChildsRolloutIsReadOnce() throws {
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(codex("SessionStart", thread: childThread, transcript: childPath), to: appState, server: server)
        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread)

        // Were it read again, the thread would now read as a root.
        _ = try writeRollout("child.jsonl", sessionMeta: rootRollout(childThread))
        let later = try route(codex("SessionStart", thread: childThread, transcript: childPath), server: server)
        XCTAssertEqual(later.raw[SubsessionRouter.linkedParentKey] as? String, parentThread)
    }

    /// Without a rollout to say so, a thread sharing a busy Codex process is
    /// only a guess at a child. Show separately does not act on it: it is the
    /// default, and a wrong guess would silence a session the user started.
    func testCodexThreadGuessedFromItsProcessStillRingsInShowSeparately() throws {
        let parentPath = try writeRollout("parent.jsonl", sessionMeta: rootRollout(parentThread))
        let missing = rolloutDir.appendingPathComponent("not-yet-written.jsonl").path
        let pid = Int(getpid())
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: parentPath, ["prompt": "go", "_ppid": pid]), to: appState, server: server)

        let stop = try deliver(codex("Stop", thread: childThread, transcript: missing, ["_ppid": pid]), to: appState, server: server)
        XCTAssertNil(stop.raw[SubsessionRouter.linkedParentKey])
        XCTAssertNil(appState.sessions[childThread]?.parentSessionId)
        XCTAssertEqual(played, ["8bit_complete"])

        // Merge acts on that guess, as it always has.
        setMode("merge")
        let merged = try route(codex("PreToolUse", thread: "019a0000-0000-7000-8000-00000000000c", transcript: missing, ["_ppid": pid]), server: server)
        XCTAssertEqual(merged.sessionId, parentThread)
    }

    /// A remote Codex root whose remote `_ppid` equals a local Codex card's
    /// process was guessed to be that card's child — by a process id from
    /// another machine — and landed on a linked, quiet card.
    func testRemoteRootSharingALocalProcessIdIsNobodysChild() throws {
        setMode("merge")
        let pid = Int(getpid())
        let appState = AppState()
        let server = HookServer(appState: appState)
        let localPath = try writeRollout("local.jsonl", sessionMeta: rootRollout(parentThread))
        try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: localPath, ["prompt": "x", "_ppid": pid]), to: appState, server: server)

        let remote = try deliver(codex("UserPromptSubmit", thread: "remote-root", transcript: "/home/u/.codex/sessions/r.jsonl", [
            "prompt": "y", "_ppid": pid, "_remote_host_id": "devbox",
        ]), to: appState, server: server)
        XCTAssertEqual(remote.sessionId, "remote-root")
        XCTAssertNil(remote.raw["agent_id"])
        XCTAssertNil(remote.raw[SubsessionRouter.linkedParentKey])
        XCTAssertNil(appState.sessions["remote:devbox:remote-root"]?.parentSessionId)
    }

    // MARK: - Codex: a child stays where it is

    func testCodexChildThatStartedOnItsOwnCardKeepsItInMerge() throws {
        setMode("merge")
        let parentPath = try writeRollout("parent.jsonl", sessionMeta: rootRollout(parentThread))
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        let appState = AppState()
        let server = HookServer(appState: appState)

        // The parent's card is not on the island yet: none is invented.
        let first = try deliver(codex("UserPromptSubmit", thread: childThread, transcript: childPath, ["prompt": "task"]), to: appState, server: server)
        XCTAssertEqual(first.sessionId, childThread)
        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread, "still a child: quiet")

        try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: parentPath, ["prompt": "go"]), to: appState, server: server)
        let later = try deliver(codex("PreToolUse", thread: childThread, transcript: childPath, ["tool_name": "exec_command"]), to: appState, server: server)
        XCTAssertEqual(later.sessionId, childThread, "its card is not stranded by the parent turning up")
        XCTAssertTrue(appState.sessions[parentThread]?.subagents.isEmpty == true)
    }

    func testCodexChildFoldedByAModeChangeFollowsItsRow() throws {
        setMode("merge")
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.providerSessionId = parentThread
        parent.status = .running
        var child = SessionSnapshot()
        child.source = "codex"
        child.providerSessionId = childThread
        child.status = .running
        child.transcriptPath = childPath
        appState.sessions[parentThread] = parent
        appState.sessions[childThread] = child

        XCTAssertTrue(appState.applyCodexSubsessionModeToKnownSessions(statePath: missingStatePath))
        XCTAssertNil(appState.sessions[childThread])
        XCTAssertEqual(appState.sessions[parentThread]?.subagents[childThread]?.subsessionKind, .codexThread)

        let next = try route(codex("PreToolUse", thread: childThread, transcript: childPath), server: HookServer(appState: appState))
        XCTAssertEqual(next.sessionId, parentThread)
        XCTAssertEqual(next.raw["agent_id"] as? String, childThread)
    }

    /// A Codex Desktop thread's first hook can come before its rollout is
    /// written: nothing says it is a child yet, so it builds a card of its
    /// own. That card is no placement of the router's, so once the rollout
    /// is readable Merge folds the thread's hooks into its parent and Hide
    /// hides them, as before; it did not keep the thread's first turn.
    func testDesktopThreadWhoseRolloutLagsItsFirstHookIsPlacedOnceItIsReadable() throws {
        let desktop: [String: Any] = ["_term_bundle": "com.openai.codex"]
        func with(_ extra: [String: Any]) -> [String: Any] {
            desktop.merging(extra) { _, new in new }
        }
        for mode in ["merge", "hide"] {
            setMode(mode)
            let parentPath = try writeRollout("parent-\(mode).jsonl", sessionMeta: rootRollout(parentThread))
            let childPath = rolloutDir.appendingPathComponent("child-\(mode).jsonl").path
            let appState = AppState()
            let server = HookServer(appState: appState)
            try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: parentPath, with(["prompt": "fan out"])), to: appState, server: server)
            try deliver(codex("SessionStart", thread: childThread, transcript: childPath, desktop), to: appState, server: server)
            XCTAssertNotNil(appState.sessions["codexapp:" + childThread], "\(mode): precondition, a card of its own")

            // The rollout is written, and its next read falls due.
            _ = try writeRollout("child-\(mode).jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
            _ = appState.codexRollouts.inspection(transcriptPath: childPath, now: Date().addingTimeInterval(2))

            let later = try deliver(
                codex("PreToolUse", thread: childThread, transcript: childPath, with(["tool_name": "exec_command"])),
                to: appState, server: server
            )
            if mode == "merge" {
                XCTAssertEqual(later.sessionId, "codexapp:" + parentThread)
                XCTAssertEqual(later.raw["agent_id"] as? String, childThread)
            } else {
                XCTAssertNotNil(later.response, "hidden")
            }
        }
    }

    // MARK: - Codex: a request waiting on a child's card

    /// Hide shows a hidden thread's request on a card of its own. The passes
    /// over known cards (every discovery scan) leave that card alone while
    /// the request waits — removing it denied the request unseen — and hide
    /// the thread again once the user has answered.
    func testHiddenCodexThreadsRequestWaitsOnItsCardThroughThePasses() async throws {
        setMode("hide")
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        appState.sessions[parentThread] = parent
        let server = HookServer(appState: appState)

        let request = try route(codex("PermissionRequest", thread: childThread, transcript: childPath, [
            "tool_name": "Bash", "tool_input": ["command": "rm -rf build"],
        ]), server: server)
        XCTAssertNil(request.response)
        let event = try XCTUnwrap(HookEvent(from: request.data))
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread)

        appState.applyCodexSubsessionModeToKnownSessions(statePath: missingStatePath)
        appState.integrateDiscovered([DiscoveredSession(
            sessionId: childThread,
            cwd: "/repo",
            tty: nil,
            model: nil,
            pid: nil,
            modifiedAt: Date(),
            recentMessages: [],
            source: "codex",
            transcriptPath: childPath,
            parentSessionId: parentThread,
            status: .idle,
            providerSessionId: childThread
        )])
        XCTAssertNotNil(appState.sessions[childThread], "its request still waits for the user")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()
        let response = String(decoding: try await awaitValue(of: task), as: UTF8.self)
        XCTAssertTrue(response.contains(#""allow""#), "the user's own answer: \(response)")

        appState.applyCodexSubsessionModeToKnownSessions(statePath: missingStatePath)
        XCTAssertNil(appState.sessions[childThread], "hidden again once answered")
    }

    /// A thread that started on its own card (its parent's was not there yet)
    /// asks on that card; Merge folds the card into its parent only once the
    /// request is answered.
    func testMergedCodexThreadsRequestOnItsOwnCardIsNotFoldedAway() async throws {
        setMode("merge")
        let parentPath = try writeRollout("parent.jsonl", sessionMeta: rootRollout(parentThread))
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(codex("UserPromptSubmit", thread: childThread, transcript: childPath, ["prompt": "task"]), to: appState, server: server)
        try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: parentPath, ["prompt": "go"]), to: appState, server: server)

        let request = try route(codex("PermissionRequest", thread: childThread, transcript: childPath, [
            "tool_name": "Bash", "tool_input": ["command": "make"],
        ]), server: server)
        XCTAssertEqual(request.sessionId, childThread)
        let event = try XCTUnwrap(HookEvent(from: request.data))
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        appState.applyCodexSubsessionModeToKnownSessions(statePath: missingStatePath)
        XCTAssertNotNil(appState.sessions[childThread])
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()
        let response = String(decoding: try await awaitValue(of: task), as: UTF8.self)
        XCTAssertTrue(response.contains(#""allow""#), response)

        appState.applyCodexSubsessionModeToKnownSessions(statePath: missingStatePath)
        XCTAssertNil(appState.sessions[childThread])
        XCTAssertEqual(appState.sessions[parentThread]?.subagents[childThread]?.subsessionKind, .codexThread)
    }

    /// Codex has filed a subagent's hook under its parent's session id, with
    /// the subagent's rollout. The rollout's answer is the file's: the
    /// parent's own hooks, naming its own rollout, are still the parent's.
    func testSubagentRolloutFiledUnderTheParentNeverHidesTheParent() throws {
        setMode("hide")
        let parentPath = try writeRollout("parent.jsonl", sessionMeta: rootRollout(parentThread))
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        appState.sessions[parentThread] = parent
        let server = HookServer(appState: appState)

        let filedUnderParent = try route(
            codex("PreToolUse", thread: parentThread, transcript: childPath, ["tool_name": "exec_command"]),
            server: server
        )
        XCTAssertNotNil(filedUnderParent.response, "the subagent's hook is hidden")
        for event in ["PreToolUse", "Stop"] {
            let own = try route(codex(event, thread: parentThread, transcript: parentPath), server: server)
            XCTAssertNil(own.response, "\(event): the parent's own hook is the parent's")
            XCTAssertNil(own.raw[SubsessionRouter.linkedParentKey], event)
        }
    }

    /// Codex has filed a subagent's hooks under its parent's session id with
    /// no `agent_id`, naming only the subagent's rollout. As they came they
    /// were the parent's own: the subagent's Stop ended the parent's turn —
    /// completion card, chime and push while the parent still worked. In
    /// every mode they go by the subagent's own id on the parent's card.
    func testThreadFiledUnderItsParentWithoutAnAgentIdNeverEndsTheParentsTurn() throws {
        let parentPath = try writeRollout("parent.jsonl", sessionMeta: rootRollout(parentThread))
        let childPath = try writeRollout("child.jsonl", sessionMeta: childRollout(childThread, parent: parentThread))
        for mode in ["separate", "merge", "hide"] {
            setMode(mode)
            played = []
            let appState = AppState()
            let server = HookServer(appState: appState)
            try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: parentPath, ["prompt": "fan out"]), to: appState, server: server)
            let tool = try deliver(codex("PreToolUse", thread: parentThread, transcript: childPath, ["tool_name": "exec_command"]), to: appState, server: server)
            try deliver(codex("Stop", thread: parentThread, transcript: childPath, ["last_assistant_message": "child done"]), to: appState, server: server)

            XCTAssertNotEqual(appState.sessions[parentThread]?.status, .idle, "\(mode): the child's Stop ended the parent's turn")
            XCTAssertNil(appState.justCompletedSessionId, mode)
            XCTAssertEqual(played, [], mode)
            if mode == "hide" {
                XCTAssertNotNil(tool.response, "hidden")
            } else {
                XCTAssertEqual(tool.sessionId, parentThread, mode)
                XCTAssertEqual(tool.raw["agent_id"] as? String, childThread, mode)
                XCTAssertEqual(tool.raw["agent_type"] as? String, "worker", mode)
            }
            XCTAssertNil(appState.sessions[parentThread]?.parentSessionId, mode)

            try deliver(codex("Stop", thread: parentThread, transcript: parentPath, ["last_assistant_message": "all done"]), to: appState, server: server)
            XCTAssertEqual(appState.justCompletedSessionId, parentThread, "\(mode): the parent's own Stop still ends its turn")
            XCTAssertEqual(played, ["8bit_complete"], mode)
        }
    }

    /// Current Codex files a spawned thread's hooks under the session that
    /// spawned it, the thread as `agent_id`. A grandchild's are then filed
    /// under its parent thread, which has no card of its own: it is a row of
    /// the root's. They built a card for that thread holding the grandchild's
    /// row, left "processing" for good. They join the root's card instead,
    /// where the grandchild's parent is — and stay there once its row ends.
    func testGrandchildFiledUnderItsParentThreadJoinsTheCardItsParentIsOn() throws {
        let grandchild = "019a0000-0000-7000-8000-00000000000c"
        let parentPath = try writeRollout("parent.jsonl", sessionMeta: rootRollout(parentThread))
        let grandPath = try writeRollout("grand.jsonl", sessionMeta: childRollout(grandchild, parent: childThread))
        let underRoot: [String: Any] = ["agent_id": childThread, "agent_type": "worker"]
        let underChild: [String: Any] = ["agent_id": grandchild, "agent_type": "explorer"]
        for mode in ["separate", "merge"] {
            setMode(mode)
            played = []
            let appState = AppState()
            let server = HookServer(appState: appState)
            try deliver(codex("UserPromptSubmit", thread: parentThread, transcript: parentPath, ["prompt": "go"]), to: appState, server: server)
            try deliver(codex("SubagentStart", thread: parentThread, transcript: parentPath, underRoot), to: appState, server: server)

            let start = try deliver(codex("SubagentStart", thread: childThread, transcript: grandPath, underChild), to: appState, server: server)
            XCTAssertEqual(start.sessionId, parentThread, mode)
            XCTAssertEqual(start.raw["agent_id"] as? String, grandchild, mode)
            XCTAssertEqual(appState.sessions[parentThread]?.subagents[grandchild]?.agentType, "explorer", mode)
            try deliver(
                codex("PreToolUse", thread: childThread, transcript: grandPath, underChild.merging(["tool_name": "exec_command"]) { _, new in new }),
                to: appState, server: server
            )
            // The parent thread's turn ends first.
            try deliver(codex("SubagentStop", thread: parentThread, transcript: parentPath, underRoot), to: appState, server: server)
            let stop = try deliver(codex("SubagentStop", thread: childThread, transcript: grandPath, underChild), to: appState, server: server)
            XCTAssertEqual(stop.sessionId, parentThread, mode)
            XCTAssertNil(appState.sessions[childThread], "\(mode): no card for the parent thread")
            XCTAssertEqual(appState.sessions[parentThread]?.subagents.isEmpty, true, mode)

            try deliver(codex("Stop", thread: parentThread, transcript: parentPath, ["last_assistant_message": "done"]), to: appState, server: server)
            XCTAssertEqual(appState.justCompletedSessionId, parentThread, mode)
            XCTAssertEqual(played, ["8bit_complete"], mode)
        }
    }

    /// Current Codex files a thread's hooks under the root's session id. In
    /// Hide its SubagentStart is hidden too, so a request it is blocked on
    /// starts its row on the root's card: under the thread's own role.
    func testHiddenCodexThreadFiledUnderItsParentAsksOnARowOfItsOwnRole() async throws {
        setMode("hide")
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        appState.sessions[parentThread] = parent
        let server = HookServer(appState: appState)
        let filed: [String: Any] = ["agent_id": childThread, "agent_type": "worker"]

        let start = try route(codex("SubagentStart", thread: parentThread, transcript: "/nonexistent.jsonl", filed), server: server)
        XCTAssertNotNil(start.response, "hidden")
        let request = try route(codex("PermissionRequest", thread: parentThread, transcript: "/nonexistent.jsonl", filed.merging([
            "tool_name": "Bash", "tool_input": ["command": "ls"],
        ]) { _, new in new }), server: server)
        XCTAssertNil(request.response)
        let event = try XCTUnwrap(HookEvent(from: request.data))
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(appState.sessions[parentThread]?.subagents[childThread]?.agentType, "worker")

        appState.handlePeerDisconnect(sessionId: parentThread, agentId: childThread)
        _ = try await awaitValue(of: task)
    }

    // MARK: - Cursor

    func testCursorTaskNamedByItsTranscriptShownSeparatelyIsQuiet() throws {
        let transcript = "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/\(cursorChat).jsonl"
        let appState = AppState()
        let server = HookServer(appState: appState)
        func cursor(_ event: String, _ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["hook_event_name": event, "session_id": id, "_source": "cursor", "transcript_path": transcript]
                .merging(extra) { _, new in new }
        }
        try deliver(cursor("beforeSubmitPrompt", cursorChat, ["prompt": "run a task"]), to: appState, server: server)
        try deliver(cursor("beforeSubmitPrompt", cursorTask, ["prompt": "task"]), to: appState, server: server)
        try deliver(cursor("stop", cursorTask), to: appState, server: server)
        XCTAssertEqual(appState.sessions[cursorTask]?.parentSessionId, cursorChat)
        XCTAssertNil(appState.justCompletedSessionId)
        XCTAssertEqual(played, [])

        try deliver(cursor("stop", cursorChat), to: appState, server: server)
        XCTAssertEqual(played, ["8bit_complete"])
        XCTAssertEqual(appState.justCompletedSessionId, cursorChat)
    }

    /// A Cursor Task's Claude-format hook (no `_source`, no transcript) can
    /// build a default "claude" card before its Cursor hooks show it is a
    /// Task of the chat on its IDE process. That card holds nothing: Merge
    /// folds the Task's hooks into its chat and Hide hides them, as before.
    func testCursorTaskWithAGhostClaudeCardIsStillFoldedOrHidden() throws {
        for mode in ["merge", "hide"] {
            setMode(mode)
            let appState = AppState()
            let server = HookServer(appState: appState)
            try deliver([
                "hook_event_name": "beforeSubmitPrompt", "session_id": cursorChat, "_source": "cursor",
                "cwd": "/cursor-repo", "_ppid": 61_101, "prompt": "run",
                "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/\(cursorChat).jsonl",
            ], to: appState, server: server)
            try deliver(
                ["hook_event_name": "PreToolUse", "session_id": cursorTask, "cwd": "/cursor-repo", "tool_name": "Read"],
                to: appState, server: server
            )
            XCTAssertEqual(appState.sessions[cursorTask]?.source, "claude", "\(mode): precondition, the ghost card")

            let shell = try deliver([
                "hook_event_name": "beforeShellExecution", "session_id": cursorTask, "_source": "cursor",
                "cwd": "/cursor-repo", "_ppid": 61_101, "command": "ls",
            ], to: appState, server: server)
            if mode == "merge" {
                XCTAssertEqual(shell.sessionId, cursorChat)
                XCTAssertEqual(shell.raw["agent_id"] as? String, cursorTask)
            } else {
                XCTAssertNotNil(shell.response, "hidden")
            }
        }
    }

    /// A Task folded in by its IDE process stays folded when a second chat on
    /// that process leaves the `_ppid` fallback unable to pick one: its Stop
    /// still closes its row, and no card of its own appears.
    func testCursorTaskFollowsItsRowWhenItsIdeProcessNoLongerSinglesOutItsChat() throws {
        setMode("merge")
        let ppid = 61_001
        let appState = AppState()
        let server = HookServer(appState: appState)
        func card(_ id: String) -> SessionSnapshot {
            var chat = SessionSnapshot()
            chat.source = "cursor"
            chat.status = .running
            chat.cliPid = pid_t(ppid)
            chat.providerSessionId = id
            chat.transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(id)/\(id).jsonl"
            return chat
        }
        appState.sessions[cursorChat] = card(cursorChat)
        func task(_ event: String) -> [String: Any] {
            ["hook_event_name": event, "session_id": cursorTask, "_source": "cursor", "_ppid": ppid]
        }

        let first = try deliver(task("beforeShellExecution"), to: appState, server: server)
        XCTAssertEqual(first.sessionId, cursorChat)
        XCTAssertEqual(appState.sessions[cursorChat]?.subagents[cursorTask]?.subsessionKind, .cursorTask)

        appState.sessions[otherChat] = card(otherChat)
        let later = try deliver(task("afterShellExecution"), to: appState, server: server)
        XCTAssertEqual(later.sessionId, cursorChat)
        try deliver(task("stop"), to: appState, server: server)
        XCTAssertNil(appState.sessions[cursorTask], "no card of its own")
        XCTAssertNil(appState.sessions[cursorChat]?.subagents[cursorTask])
    }

    /// The Cursor pass runs after any hook while a default-Claude card is on
    /// the island. It leaves a hidden Task's card alone while a request on it
    /// waits, and hides the Task again once the request is answered.
    func testHiddenCursorTasksRequestWaitsThroughTheCursorPass() async throws {
        setMode("hide")
        let cursorIndexScanner: @Sendable () -> CursorSubagentTranscriptIndex = { CursorSubagentTranscriptIndex(pathsBySessionId: [:], builtAt: Date()) }

        let appState = AppState()
        appState.discovery.scanners.cursorSubagentIndex = cursorIndexScanner
        var chat = SessionSnapshot()
        chat.source = "cursor"
        chat.status = .running
        chat.transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/\(cursorChat).jsonl"
        appState.sessions[cursorChat] = chat
        var claude = SessionSnapshot()
        claude.source = "claude"
        claude.status = .processing
        appState.sessions["claude-session"] = claude
        let server = HookServer(appState: appState)

        let request = try route([
            "hook_event_name": "PermissionRequest", "session_id": cursorTask, "_source": "cursor",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/subagents/\(cursorTask).jsonl",
            "tool_name": "Shell", "tool_input": ["command": "ls"],
        ], server: server)
        XCTAssertNil(request.response)
        let event = try XCTUnwrap(HookEvent(from: request.data))
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        // Another session's hook runs the Cursor pass.
        appState.handleEvent(try XCTUnwrap(HookEvent(json: [
            "hook_event_name": "PostToolUse", "session_id": "claude-session", "tool_name": "Read",
        ])))
        XCTAssertNotNil(appState.sessions[cursorTask], "its request still waits for the user")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()
        let response = String(decoding: try await awaitValue(of: task), as: UTF8.self)
        XCTAssertTrue(response.contains(#""allow""#), response)
        appState.applyCursorSubsessionModeToKnownSessions()
        XCTAssertNil(appState.sessions[cursorTask], "hidden again once answered")
    }

    // MARK: - Plugin proxies

    /// Hide used to answer a proxy's permission request `allow`. It now goes
    /// back to the agent undecided (`{}`, as with no hook installed), so the
    /// agent asks the user itself; the proxy stays hidden throughout.
    func testHiddenPluginProxyRequestGoesBackToItsAgentUndecided() throws {
        setMode("hide")
        let appState = AppState()
        let server = HookServer(appState: appState)
        func proxy(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["hook_event_name": event, "session_id": "ses_proxy", "_source": "opencode", "_via_plugin": true, "_ppid": 62_001]
                .merging(extra) { _, new in new }
        }

        for payload in [
            proxy("PreToolUse", ["tool_name": "bash"]),
            proxy("PermissionRequest", ["tool_name": "bash", "tool_input": ["command": "rm -rf build"]]),
            proxy("PermissionRequest", [
                "tool_name": "AskUserQuestion",
                "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"]]]]],
            ]),
            proxy("Stop"),
        ] {
            let routed = try route(payload, server: server)
            XCTAssertEqual(routed.response.flatMap { String(data: $0, encoding: .utf8) }, "{}", "\(payload["hook_event_name"]!)")
        }
        XCTAssertNil(appState.sessions["ses_proxy"])
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertEqual(played, [])
    }

    func testMergedPluginProxyJoinsItsAgentsCardAsItsOwnEvents() throws {
        setMode("merge")
        let ppid = 62_002
        let appState = AppState()
        var main = SessionSnapshot()
        main.source = "opencode"
        main.status = .running
        main.cliPid = pid_t(ppid)
        appState.sessions["opencode-main"] = main
        let routed = try route([
            "hook_event_name": "PostToolUse", "session_id": "ses_proxy",
            "_source": "opencode", "_via_plugin": true, "_ppid": ppid,
        ], server: HookServer(appState: appState))
        XCTAssertEqual(routed.sessionId, "opencode-main")
        XCTAssertNil(routed.raw["agent_id"])
    }

    // MARK: - Every known child shown separately is linked

    func testShowingFoldedChildrenSeparatelyLinksTheirNewCards() throws {
        let appState = AppState()
        var codexParent = SessionSnapshot()
        codexParent.source = "codex"
        codexParent.status = .running
        codexParent.subagents[childThread] = SubagentState(agentId: childThread, agentType: "worker")
        appState.sessions[parentThread] = codexParent
        var chat = SessionSnapshot()
        chat.source = "cursor"
        chat.status = .running
        chat.providerSessionId = cursorChat
        chat.subagents[cursorTask] = SubagentState(agentId: cursorTask, agentType: "cursor-subagent")
        appState.sessions[cursorChat] = chat

        appState.applyCurrentPluginSessionMode(persist: false)

        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread)
        XCTAssertEqual(appState.sessions[cursorTask]?.parentSessionId, cursorChat)
        XCTAssertNil(appState.sessions[parentThread]?.parentSessionId)
        XCTAssertNil(appState.sessions[cursorChat]?.parentSessionId)
    }

    /// The split's link is on the card, not in the thread's hooks: a
    /// SessionStart the router cannot resolve (its rollout not readable)
    /// rebuilt the card without it, and the thread rang like a root again.
    func testSplitChildKeepsItsLinkThroughAnUnresolvedSessionStart() throws {
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.subagents[childThread] = SubagentState(agentId: childThread, agentType: "worker")
        appState.sessions[parentThread] = parent
        appState.applyCurrentPluginSessionMode(persist: false)
        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread, "precondition: the split linked it")

        let missing = rolloutDir.appendingPathComponent("not-yet-written.jsonl").path
        try deliver(codex("SessionStart", thread: childThread, transcript: missing), to: appState, server: HookServer(appState: appState))
        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread)
        XCTAssertEqual(played, [], "still quiet")
    }

    func testDiscoveredCodexChildShownSeparatelyIsLinked() {
        let appState = AppState()
        appState.integrateDiscovered([DiscoveredSession(
            sessionId: childThread,
            cwd: "/repo",
            tty: nil,
            model: nil,
            pid: nil,
            modifiedAt: Date(),
            recentMessages: [],
            source: "codex",
            parentSessionId: parentThread,
            agentType: "worker",
            status: .processing,
            providerSessionId: childThread
        )])
        XCTAssertEqual(appState.sessions[childThread]?.parentSessionId, parentThread)

        appState.integrateDiscovered([DiscoveredSession(
            sessionId: parentThread,
            cwd: "/repo",
            tty: nil,
            model: nil,
            pid: nil,
            modifiedAt: Date(),
            recentMessages: [],
            source: "codex",
            status: .processing,
            providerSessionId: parentThread
        )])
        XCTAssertNil(appState.sessions[parentThread]?.parentSessionId)
    }

    /// A Codex CLI discovery names no provider thread, so discovery can merge
    /// it into another card of the same cwd and process as a duplicate — a
    /// root's. That card is not the discovered thread's and is never linked:
    /// the root keeps ringing.
    func testDiscoveryNeverLinksTheCardADuplicateWasMergedInto() throws {
        let appState = AppState()
        var root = SessionSnapshot()
        root.source = "codex"
        root.cwd = "/repo"
        root.status = .processing
        root.cliPid = getpid()
        root.lastActivity = Date(timeIntervalSinceNow: -60)
        appState.sessions[parentThread] = root

        let grandchild = "019a0000-0000-7000-8000-0000000000cc"
        appState.integrateDiscovered([DiscoveredSession(
            sessionId: grandchild,
            cwd: "/repo",
            tty: nil,
            model: nil,
            pid: getpid(),
            modifiedAt: Date(),
            recentMessages: [],
            source: "codex",
            parentSessionId: childThread,
            status: .processing
        )])
        XCTAssertNil(appState.sessions[grandchild], "merged into the root's card as a duplicate")
        XCTAssertNil(appState.sessions[parentThread]?.parentSessionId)

        appState.handleEvent(try XCTUnwrap(HookEvent(json: [
            "hook_event_name": "Stop", "session_id": parentThread, "_source": "codex", "cwd": "/repo",
            "last_assistant_message": "done",
        ])))
        XCTAssertEqual(appState.justCompletedSessionId, parentThread)
        XCTAssertEqual(played, ["8bit_complete"])
    }
}
