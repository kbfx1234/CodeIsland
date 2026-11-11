import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Model / reasoning-effort label wiring in AppState: live tail deltas,
/// subagents' own models read from their transcripts, Codex rollouts.
@MainActor
final class AppStateModelLabelTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-AppStateModelLabelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func recapLine(_ text: String, timestamp: String = "2026-09-12T03:35:41.545Z") -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"away_summary","content":"\#(text) (disable recaps in /config)","timestamp":"\#(timestamp)","uuid":"u","isMeta":false,"sessionId":"s"}"#
    }

    private func userLine(_ text: String) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u"}"#
    }

    private func assistantLine(model: String, effort: String, sidechain: Bool = false) -> String {
        #"{"parentUuid":"p","isSidechain":\#(sidechain),"message":{"model":"\#(model)","role":"assistant","content":[{"type":"text","text":"ok"}]},"type":"assistant","effort":"\#(effort)","uuid":"u"}"#
    }

    private func writeTranscript(_ lines: [String], name: String = "session.jsonl") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testModelDeltaUpdatesTheLabel() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.model = "claude-opus-5-5[1m]"
        appState.sessions["s1"] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: "hi",
            modelObservation: ModelObservation(model: "claude-opus-5-5", effort: "xhigh")
        ))

        XCTAssertEqual(appState.sessions["s1"]?.modelLabel, "Opus 5.5 1M · xhigh")
    }

    func testResumeWithADifferentModelKeepsTheModelTheHookReported() throws {
        // `claude --resume <id> --model sonnet` over a transcript that ran on Opus.
        let path = try writeTranscript([
            userLine("earlier work"),
            #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"ok"}]},"type":"assistant","effort":"xhigh","timestamp":"2026-09-01T10:00:00.000Z","uuid":"u"}"#,
        ], name: "resume.jsonl")
        let appState = AppState()
        defer { appState.detachTranscriptTailer(sessionId: "resumed") }
        func hook(_ payload: [String: Any]) throws -> HookEvent {
            var payload = payload
            payload["session_id"] = "resumed"
            payload["transcript_path"] = path
            payload["cwd"] = tempDir.path
            return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        }

        appState.handleEvent(try hook(["hook_event_name": "SessionStart", "source": "resume", "model": "claude-sonnet-5"]))
        appState.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "prompt": "carry on"]))

        XCTAssertEqual(appState.attachedTranscriptPaths["resumed"], path, "the attach backfill ran")
        XCTAssertEqual(appState.sessions["resumed"]?.model, "claude-sonnet-5")
        XCTAssertNil(appState.sessions["resumed"]?.reasoningEffort, "Opus's effort is not Sonnet's")
    }

    // MARK: - Subagents' own models

    private func hook(_ payload: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private func claudeParent(_ parentPath: String, subagent agentId: String) -> AppState {
        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "claude"
        parent.transcriptPath = parentPath
        parent.model = "claude-opus-5-5"
        parent.subagents[agentId] = SubagentState(agentId: agentId, agentType: "Explore")
        appState.sessions["sess"] = parent
        return appState
    }

    func testClaudeSubagentModelComesFromItsOwnTranscriptNotTheParent() async throws {
        let parentPath = try writeTranscript(
            [assistantLine(model: "claude-opus-5-5", effort: "xhigh")],
            name: "proj/sess.jsonl"
        )
        _ = try writeTranscript(
            [
                #"{"isSidechain":true,"type":"user","message":{"role":"user","content":"look"}}"#,
                assistantLine(model: "claude-haiku-4-5-20251001", effort: "low", sidechain: true),
            ],
            name: "proj/sess/subagents/agent-a1.jsonl"
        )
        let appState = claudeParent(parentPath, subagent: "a1")
        let event = try hook(["hook_event_name": "PreToolUse", "session_id": "sess", "agent_id": "a1"])
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a1", event: event)
        // The file is read off the main actor.
        await waitUntil { appState.sessions["sess"]?.subagents["a1"]?.model != nil }

        let sub = appState.sessions["sess"]?.subagents["a1"]
        XCTAssertEqual(sub?.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(sub?.reasoningEffort, "low")
        XCTAssertEqual(sub?.modelLabel, "Haiku 4.5 · low")
        XCTAssertEqual(appState.sessions["sess"]?.model, "claude-opus-5-5")

        // Codex-style recreation of the SubagentState reuses the cached read.
        appState.sessions["sess"]?.subagents["a1"] = SubagentState(agentId: "a1", agentType: "Explore")
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a1", event: event)
        XCTAssertEqual(appState.sessions["sess"]?.subagents["a1"]?.model, "claude-haiku-4-5-20251001")
    }

    func testWorkflowSubagentTranscriptTwoLevelsDownIsFound() throws {
        // Claude Code 2.1.25x writes workflow agents to
        // <session>/subagents/workflows/wf_<run>/agent-<id>.jsonl.
        let parentPath = try writeTranscript([userLine("x")], name: "proj/sess.jsonl")
        _ = try writeTranscript([userLine("other run")], name: "proj/sess/subagents/workflows/wf_1b0c2f/agent-a9.jsonl")
        _ = try writeTranscript(
            [
                #"{"parentUuid":null,"isSidechain":true,"agentId":"a029fb2","type":"user","message":{"role":"user","content":"analyse the paper"}}"#,
                #"{"parentUuid":"p","isSidechain":true,"agentId":"a029fb2","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"ok"}]},"attributionAgent":"workflow-subagent","type":"assistant","effort":"xhigh","timestamp":"2026-08-29T06:04:24.608Z"}"#,
            ],
            name: "proj/sess/subagents/workflows/wf_2ccf82-29a/agent-a029fb2.jsonl"
        )
        XCTAssertEqual(
            AppState.readClaudeSubagentModel(parentTranscriptPath: parentPath, agentId: "a029fb2"),
            ModelObservation(model: "claude-opus-5", effort: "xhigh")
        )
        // One grouping level still works.
        _ = try writeTranscript(
            [assistantLine(model: "claude-sonnet-5", effort: "medium", sidechain: true)],
            name: "proj/sess/subagents/run-1/agent-a2.jsonl"
        )
        XCTAssertEqual(
            AppState.readClaudeSubagentModel(parentTranscriptPath: parentPath, agentId: "a2"),
            ModelObservation(model: "claude-sonnet-5", effort: "medium")
        )
        XCTAssertNil(AppState.readClaudeSubagentModel(parentTranscriptPath: parentPath, agentId: "missing"))
    }

    func testTheHooksOwnSubagentTranscriptPathIsUsedAndRemembered() async throws {
        let parentPath = try writeTranscript([userLine("x")], name: "proj/sess.jsonl")
        let childPath = try writeTranscript(
            [assistantLine(model: "claude-haiku-4-5", effort: "low", sidechain: true)],
            name: "elsewhere/agent-a4.jsonl"
        )
        let appState = claudeParent(parentPath, subagent: "a4")
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a4", event: try hook([
            "hook_event_name": "SubagentStop", "session_id": "sess", "agent_id": "a4",
            "agent_transcript_path": childPath,
        ]))
        await waitUntil { appState.sessions["sess"]?.subagents["a4"]?.model != nil }
        XCTAssertEqual(appState.sessions["sess"]?.subagents["a4"]?.modelLabel, "Haiku 4.5 · low")
    }

    func testMissingSubagentTranscriptBacksOffAndGivesUp() async throws {
        let parentPath = try writeTranscript([userLine("x")], name: "proj/sess.jsonl")
        let appState = claudeParent(parentPath, subagent: "a3")
        let event = try hook(["hook_event_name": "SubagentStart", "session_id": "sess", "agent_id": "a3"])

        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a3", event: event)
        await waitUntil { appState.subagentModelReads["sess"]?["a3"]?.inFlight == false }
        let first = try XCTUnwrap(appState.subagentModelReads["sess"]?["a3"])
        XCTAssertNil(appState.sessions["sess"]?.subagents["a3"]?.model)
        XCTAssertEqual(first.attempts, 1)
        XCTAssertGreaterThan(first.retryAt, Date())

        // Hooks inside the cooldown don't read again.
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a3", event: event)
        XCTAssertEqual(appState.subagentModelReads["sess"]?["a3"]?.attempts, 1)

        // Each miss waits longer, and the reads stop at the cap.
        var read = first
        read.retryAt = .distantPast
        appState.subagentModelReads["sess"]?["a3"] = read
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a3", event: event)
        await waitUntil { appState.subagentModelReads["sess"]?["a3"]?.inFlight == false }
        let second = try XCTUnwrap(appState.subagentModelReads["sess"]?["a3"])
        XCTAssertEqual(second.attempts, 2)
        XCTAssertGreaterThan(
            second.retryAt.timeIntervalSinceNow,
            AppState.subagentModelReadRetryInterval * 1.5,
            "the second wait is longer than the first"
        )

        read = second
        read.attempts = AppState.subagentModelReadMaxAttempts
        read.retryAt = .distantPast
        appState.subagentModelReads["sess"]?["a3"] = read
        appState.maybeBackfillSubagentModel(sessionId: "sess", agentId: "a3", event: event)
        XCTAssertEqual(appState.subagentModelReads["sess"]?["a3"]?.inFlight, false, "no read after the last attempt")
    }

    func testCodexChildEffortIsFoundBeyondTheTailWindow() async throws {
        // A forked child thread: its session_meta, a copy of the parent's
        // history, its own turn_context, then more than 128 KB of tool output.
        var lines = [
            #"{"timestamp":"2026-09-23T12:00:00.000Z","type":"session_meta","payload":{"id":"child-thread","cwd":"/repo","originator":"codex_cli_rs","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1}}},"model_provider":"openai"}}"#,
            #"{"timestamp":"2026-09-23T11:00:00.000Z","type":"turn_context","payload":{"turn_id":"parent-turn","cwd":"/repo","model":"gpt-5.6-sol","effort":"low","summary":"auto"}}"#,
            #"{"timestamp":"2026-09-23T12:00:01.000Z","type":"turn_context","payload":{"turn_id":"child-turn","cwd":"/repo","model":"gpt-5.6-sol","effort":"max","summary":"auto"}}"#,
        ]
        let output = String(repeating: "o", count: 4_000)
        for index in 0..<40 {
            lines.append(#"{"timestamp":"2026-09-23T12:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_\#(index)","output":"\#(output)"}}"#)
        }
        let childPath = try writeTranscript(lines, name: "rollout-child.jsonl")
        XCTAssertNil(JSONLTailer.scanFileTail(path: childPath)?.modelObservation, "fixture: out of the 128 KB window")

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.transcriptPath = try writeTranscript([userLine("x")], name: "rollout-parent.jsonl")
        parent.subagents["child-thread"] = SubagentState(agentId: "child-thread", agentType: "worker")
        parent.subagents["child-thread"]?.model = "gpt-5.6-sol"
        appState.sessions["parent"] = parent

        appState.maybeBackfillSubagentModel(sessionId: "parent", agentId: "child-thread", event: try hook([
            "hook_event_name": "PreToolUse", "session_id": "parent", "agent_id": "child-thread",
            "_source": "codex", "transcript_path": childPath,
        ]))
        await waitUntil { appState.sessions["parent"]?.subagents["child-thread"]?.reasoningEffort != nil }
        XCTAssertEqual(appState.sessions["parent"]?.subagents["child-thread"]?.modelLabel, "gpt-5.6-sol · max")
    }

    func testCodexAttachFindsTheTurnContextBeyondTheTailWindow() async throws {
        var lines = [
            #"{"timestamp":"2026-09-23T12:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/repo","model":"gpt-5.6-sol","effort":"xhigh","summary":"auto"}}"#,
        ]
        let output = String(repeating: "o", count: 4_000)
        for index in 0..<40 {
            lines.append(#"{"timestamp":"2026-09-23T12:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_\#(index)","output":"\#(output)"}}"#)
        }
        let path = try writeTranscript(lines, name: "rollout-main.jsonl")
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "codex"
        session.model = "gpt-5.6-sol"
        session.transcriptPath = path
        appState.sessions["main"] = session
        defer { appState.detachTranscriptTailer(sessionId: "main") }

        appState.attachTranscriptTailerIfNeeded(sessionId: "main")
        await waitUntil { appState.sessions["main"]?.reasoningEffort != nil }
        XCTAssertEqual(appState.sessions["main"]?.modelLabel, "gpt-5.6-sol · xhigh")
    }

    // MARK: - Codex rollout model

    func testCodexBackfillPrefersTurnContextModelOverProvider() throws {
        let path = try writeTranscript([
            #"{"timestamp":"t","type":"session_meta","payload":{"id":"x","cwd":"/r","model_provider":"openai"}}"#,
            #"{"timestamp":"t","type":"turn_context","payload":{"cwd":"/r","model":"gpt-5.6-sol","effort":"max"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"go"}}"#,
        ], name: "rollout.jsonl")

        XCTAssertEqual(CodexDiscovery.readRecentFromCodexTranscript(path: path).0, "gpt-5.6-sol")
    }
}
