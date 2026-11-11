import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Cursor runs the Claude Code hooks it imports from ~/.claude/settings.json
/// with its own payload, beside its own ~/.cursor/hooks.json (#377). Those
/// events are Cursor's, a step wired in both configs is still one event, and a
/// Task they report still folds under its chat.
@MainActor
final class CursorImportedClaudeHookTests: XCTestCase {
    private let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
    private let siblingId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
    private let workspace = "/Users/u/project"
    private let extensionHostPid = 56_377

    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]
    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundTaskComplete,
        SettingsKey.soundPromptSubmit,
        SettingsKey.quietHoursEnabled,
        SettingsKey.pluginSessionMode,
    ]

    override func setUp() {
        super.setUp()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskComplete)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundPromptSubmit)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.set("separate", forKey: SettingsKey.pluginSessionMode)
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
        super.tearDown()
    }

    // MARK: - One event per step

    /// `beforeSubmitPrompt` and `stop` are in both of CodeIsland's configs, so
    /// Cursor runs two hooks for each with one payload. The island heard every
    /// prompt and every finished turn twice.
    func testAStepBothConfigsReportChimesOnce() throws {
        let appState = AppState()
        for turn in 1...2 {
            let generation = "gen-\(turn)"
            let prompt = cursorPayload(
                session: parentId, event: "beforeSubmitPrompt", generation: generation,
                extra: ["prompt": "Fix the flaky test (\(turn))"]
            )
            let stop = cursorPayload(
                session: parentId, event: "stop", generation: generation,
                extra: ["status": "completed", "loop_count": 0]
            )
            for payload in [prompt, stop] {
                // Cursor's own hooks.json copy, then the imported Claude Code one:
                // Cursor runs each config's hooks in that config's folder.
                appState.handleEvent(try bridged(payload, hookCwd: NSHomeDirectory() + "/.cursor"))
                appState.handleEvent(try bridged(payload, hookCwd: NSHomeDirectory() + "/.claude"))
            }
        }

        XCTAssertEqual(played, ["8bit_submit", "8bit_complete", "8bit_submit", "8bit_complete"])
        XCTAssertEqual(Array(appState.sessions.keys), [parentId])
        XCTAssertEqual(appState.sessions[parentId]?.source, "cursor")
        XCTAssertEqual(appState.sessions[parentId]?.status, .idle)
        XCTAssertEqual(appState.sessions[parentId]?.cwd, workspace)
        XCTAssertEqual(appState.sessions[parentId]?.lastUserPrompt, "Fix the flaky test (2)")
    }

    /// The filter is Cursor's alone: other agents' hooks carry no digest and
    /// every delivery stays an event.
    func testOtherAgentsKeepEveryDelivery() throws {
        let appState = AppState()
        let prompt: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "claude-session",
            "prompt": "again",
            "_source": "claude",
        ]
        for _ in 0..<2 {
            appState.handleEvent(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: prompt))))
        }
        XCTAssertEqual(played, ["8bit_submit", "8bit_submit"])
    }

    // MARK: - The bridge

    /// The real bridge on the hook as Cursor runs it: CodeIsland's Claude Code
    /// hook (no `--source`) and its hooks.json entry, from two folders. Both
    /// copies are Cursor's, neither is a plugin proxy, and both carry the same
    /// digest although the `cwd` the bridge fills in differs.
    func testBridgeLabelsBothCopiesCursorWithOneDigest() throws {
        let stdin = try JSONSerialization.data(withJSONObject: cursorPayload(
            session: parentId, event: "stop", generation: "gen-1", extra: ["status": "completed", "loop_count": 0]
        ))
        let claudeCopy = try runBridge(args: [], stdin: stdin, cwd: "claude")
        let cursorCopy = try runBridge(args: ["--source", "cursor", "--event", "stop"], stdin: stdin, cwd: "cursor")

        for copy in [claudeCopy, cursorCopy] {
            XCTAssertEqual(copy.status, 0)
            XCTAssertEqual(copy.stdout, "")
            XCTAssertEqual(copy.forwarded["_source"] as? String, "cursor")
            XCTAssertNil(copy.forwarded["_via_plugin"])
            XCTAssertEqual(copy.forwarded["session_id"] as? String, parentId)
        }
        let digest = try XCTUnwrap(claudeCopy.forwarded[CursorHookPayload.digestKey] as? String)
        XCTAssertEqual(cursorCopy.forwarded[CursorHookPayload.digestKey] as? String, digest)
        XCTAssertEqual(digest, CursorHookPayload.deliveryDigest(of: stdin))
        XCTAssertNotEqual(claudeCopy.forwarded["cwd"] as? String, cursorCopy.forwarded["cwd"] as? String)
    }

    /// Cursor imports neither Claude Code's PermissionRequest nor its
    /// Notification hook today. Should a Cursor payload ever name one, the
    /// bridge still neither waits on the island nor prints its answer: Cursor
    /// reads stdout against its own schema.
    func testBridgeNeverHoldsOrAnswersACursorHook() throws {
        var payload = cursorPayload(session: parentId, event: "PermissionRequest", generation: "gen-1")
        payload["tool_name"] = "Shell"
        payload["question"] = "Run swift test?"
        let stdin = try JSONSerialization.data(withJSONObject: payload)
        let allow = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)

        let started = Date()
        let run = try runBridge(args: [], stdin: stdin, cwd: "claude", reply: allow)

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "", "no island decision on a Cursor hook's stdout")
        XCTAssertEqual(run.forwarded["_source"] as? String, "cursor")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - Tasks still fold

    /// A Task's own hooks carry no transcript (Cursor resolves one only for a
    /// top-level chat). Labelled Cursor now, the hook takes the `_ppid` route
    /// onto the one chat running in that Cursor window.
    func testRelabelledTaskHookFoldsUnderItsChatByPid() throws {
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        let appState = AppState()
        appState.sessions[parentId] = runningChat(parentId)

        let event = try routed(appState, try bridgedRaw(taskToolUse()))
        appState.handleEvent(event)

        XCTAssertNil(appState.sessions[childId])
        XCTAssertEqual(appState.sessions[parentId]?.subagents[childId]?.currentTool, "Read")
        XCTAssertEqual(appState.sessions[parentId]?.subagents[childId]?.agentType, "cursor-subagent")
    }

    /// With two chats in the window the pid says nothing; the Task's transcript
    /// on disk (`agent-transcripts/<chat>/subagents/<task>.jsonl`) does. The
    /// index lookup used to cover default-Claude cards only, so a Task card the
    /// bridge labels Cursor must be a candidate too, or it never folds.
    func testRelabelledTaskHookFoldsUnderTheChatItsTranscriptNames() async throws {
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        let childId = self.childId
        let taskTranscript = "/Users/u/.cursor/projects/\(workspace.appProjectDirEncoded())/agent-transcripts/"
            + "\(parentId)/subagents/\(childId).jsonl"
        let cursorIndexScanner: @Sendable () -> CursorSubagentTranscriptIndex = {
            CursorSubagentTranscriptIndex(pathsBySessionId: [childId: [taskTranscript]], builtAt: Date())
        }

        let appState = AppState()
        appState.discovery.scanners.cursorSubagentIndex = cursorIndexScanner
        appState.sessions[parentId] = runningChat(parentId)
        appState.sessions[siblingId] = runningChat(siblingId)

        let event = try routed(appState, try bridgedRaw(taskToolUse()))
        XCTAssertEqual(event.sessionId, childId, "two chats on one pid: no guess")
        appState.handleEvent(event)
        XCTAssertEqual(appState.sessions[childId]?.source, "cursor")

        await waitUntil("the index walk never folded the relabelled Task card") {
            appState.sessions[childId] == nil
        }
        XCTAssertEqual(appState.sessions[parentId]?.subagents[childId]?.currentTool, "Read")
        XCTAssertNil(appState.sessions[siblingId]?.subagents[childId])
    }

    /// A new chat's first hook, `sessionStart`, comes before Cursor has a
    /// transcript for it. With one other chat in the window, the `_ppid` route
    /// would make the new chat that chat's Task — which then never finishes.
    func testNewChatsSessionStartIsNotAdoptedByAnotherChat() throws {
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        let appState = AppState()
        appState.sessions[siblingId] = runningChat(siblingId)

        var start = cursorPayload(session: parentId, event: "sessionStart", generation: "")
        start["transcript_path"] = NSNull()
        start["composer_mode"] = "agent"
        let event = try routed(appState, try bridgedRaw(start))
        appState.handleEvent(event)

        XCTAssertEqual(event.sessionId, parentId)
        XCTAssertEqual(appState.sessions[parentId]?.source, "cursor")
        XCTAssertEqual(appState.sessions[siblingId]?.subagents.isEmpty, true)
    }

    func testTranscriptLookupCandidates() {
        var claude = SessionSnapshot()
        claude.source = "claude"
        XCTAssertTrue(AppState.needsCursorTaskTranscriptLookup(claude))

        var task = SessionSnapshot()
        task.source = "cursor"
        XCTAssertTrue(AppState.needsCursorTaskTranscriptLookup(task))
        task.source = "cursor-cli"
        XCTAssertTrue(AppState.needsCursorTaskTranscriptLookup(task))

        var chat = task
        chat.transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
        XCTAssertFalse(AppState.needsCursorTaskTranscriptLookup(chat))

        var remote = task
        remote.remoteHostId = "devbox"
        XCTAssertFalse(AppState.needsCursorTaskTranscriptLookup(remote), "nothing on this Mac to find")

        var codex = SessionSnapshot()
        codex.source = "codex"
        XCTAssertFalse(AppState.needsCursorTaskTranscriptLookup(codex))
    }

    // MARK: - Helpers

    /// A hook input as Cursor builds it: one per step, for every hook of the step.
    private func cursorPayload(
        session: String,
        event: String,
        generation: String,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "conversation_id": session,
            "generation_id": generation,
            "session_id": session,
            "model": "composer-2.5",
            "hook_event_name": event,
            "cursor_version": "3.25.9",
            "workspace_roots": [workspace],
            "user_email": NSNull(),
            "transcript_path": chatTranscript(session),
        ]
        payload.merge(extra) { _, new in new }
        return payload
    }

    private func chatTranscript(_ id: String) -> String {
        "/Users/u/.cursor/projects/Users-u-project/agent-transcripts/\(id)/\(id).jsonl"
    }

    /// The Task's own `preToolUse`: its own conversation id, no transcript.
    private func taskToolUse() -> [String: Any] {
        var payload = cursorPayload(
            session: childId, event: "preToolUse", generation: "gen-task",
            extra: [
                "tool_name": "Read",
                "tool_input": ["file_path": "\(workspace)/Sources/App.swift"],
                "tool_use_id": "call_task_1",
                "cwd": "",
            ]
        )
        payload["transcript_path"] = NSNull()
        return payload
    }

    /// What the bridge forwards for `payload` (see CodeIslandBridge/main.swift):
    /// it fills `cwd` in from the folder Cursor ran the hook in when the
    /// payload has none.
    private func bridgedRaw(_ payload: [String: Any], hookCwd: String? = nil) throws -> [String: Any] {
        let stdin = try JSONSerialization.data(withJSONObject: payload)
        var json = payload
        json["_source"] = "cursor"
        json["_ppid"] = extensionHostPid
        json[CursorHookPayload.digestKey] = CursorHookPayload.deliveryDigest(of: stdin)
        if json["cwd"] == nil {
            json["cwd"] = hookCwd ?? NSHomeDirectory() + "/.claude"
        }
        return json
    }

    private func bridged(_ payload: [String: Any], hookCwd: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: bridgedRaw(payload, hookCwd: hookCwd))))
    }

    /// Through HookServer's Agent Sub-Sessions routing, as a delivery would go.
    private func routed(_ appState: AppState, _ raw: [String: Any]) throws -> HookEvent {
        let server = HookServer(appState: appState)
        let routed = server.routeSubsessionPayloadIfNeededForTesting(data: try JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(routed.responseData)
        return try XCTUnwrap(HookEvent(from: routed.processedData))
    }

    private func runningChat(_ id: String) -> SessionSnapshot {
        var chat = SessionSnapshot()
        chat.source = "cursor"
        chat.status = .running
        chat.cwd = workspace
        chat.cliPid = pid_t(extensionHostPid)
        chat.providerSessionId = id
        chat.transcriptPath = chatTranscript(id)
        chat.lastActivity = Date()
        return chat
    }

    private func runBridge(
        args: [String],
        stdin: Data,
        cwd folder: String,
        reply: Data = Data("{}".utf8)
    ) throws -> (status: Int32, stdout: String, forwarded: [String: Any]) {
        let bridge = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("codeisland-bridge")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else {
            throw XCTSkip("codeisland-bridge not built next to the test bundle")
        }
        let server = try XCTUnwrap(OneShotUnixServer(reply: reply))
        let scratch = NSTemporaryDirectory() + "codeisland-bridge-377-\(UUID().uuidString)"
        let hookFolder = "\(scratch)/\(folder)"
        try FileManager.default.createDirectory(atPath: hookFolder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: scratch) }

        let process = Process()
        process.executableURL = bridge
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: hookFolder)
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CODEISLAND_SOCKET_PATH": server.path,
            "CODEISLAND_BRIDGE_LOG": "\(scratch)/bridge.log",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertTrue(server.waitUntilServed(timeout: 5))
        let forwarded = try XCTUnwrap(JSONSerialization.jsonObject(with: server.received) as? [String: Any])
        return (process.terminationStatus, String(decoding: printed, as: UTF8.self), forwarded)
    }
}
