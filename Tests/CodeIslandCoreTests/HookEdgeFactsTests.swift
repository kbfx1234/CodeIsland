import Foundation
import XCTest
@testable import CodeIslandCore

/// An edge that cannot run Swift sends facts (`_edge`) and gets the bridge's
/// interpretation of them (HookIntake) — the remote hook above all.
final class HookEdgeFactsTests: XCTestCase {
    private let remoteHost: [String: Any] = ["id": "devbox", "name": "Dev Box"]

    private func interpret(
        _ payload: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HookIntake {
        let delivery = try XCTUnwrap(
            HookEdgeFacts.delivery(in: payload),
            "no facts read",
            file: file, line: line
        )
        guard case .interpreted(let intake) = delivery else {
            XCTFail("dropped", file: file, line: line)
            throw XCTSkip("dropped")
        }
        return intake
    }

    private func remoteEdge(source: String, extra: [String: Any] = [:]) -> [String: Any] {
        var edge: [String: Any] = [
            "v": 1,
            "source": source,
            "host": remoteHost,
            "cwd": "/home/dev/project",
            "stdin_sha256": "abc123",
        ]
        edge.merge(extra) { _, new in new }
        return edge
    }

    // MARK: - The remote hook

    func testRemoteClaudeHookIsClaudeOnItsHost() throws {
        let intake = try interpret([
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "cwd": "/home/dev/project",
            "_edge": remoteEdge(source: "claude", extra: ["tty": "/dev/pts/3"]),
        ])
        XCTAssertEqual(intake.payload["_source"] as? String, "claude")
        XCTAssertNil(intake.payload["_via_plugin"])
        XCTAssertEqual(intake.payload["_remote_host_id"] as? String, "devbox")
        XCTAssertEqual(intake.payload["_remote_host_name"] as? String, "Dev Box")
        XCTAssertEqual(intake.payload["_tty"] as? String, "/dev/pts/3")
        XCTAssertEqual(intake.payload["cwd"] as? String, "/home/dev/project")
        XCTAssertNil(intake.payload["_edge"], "facts are not part of the event")
        XCTAssertNil(intake.payload["_ppid"], "a remote process is not this Mac's to track")
        XCTAssertNil(intake.payload["_hook_ppid"])
        XCTAssertNil(intake.payload[CursorHookPayload.digestKey])
        XCTAssertFalse(intake.waitsForAnswer)
    }

    /// #377 over Remote-SSH: Cursor runs the Claude Code hooks it imports, so
    /// its events reach the remote hook installed for Claude.
    func testCursorRunningTheRemoteClaudeHookIsCursor() throws {
        let intake = try interpret([
            "hook_event_name": "stop",
            "session_id": "conv-1",
            "conversation_id": "conv-1",
            "cursor_version": "3.25.9",
            "status": "completed",
            "_edge": remoteEdge(source: "claude"),
        ])
        XCTAssertEqual(intake.payload["_source"] as? String, "cursor")
        XCTAssertNil(intake.payload["_via_plugin"])
        XCTAssertEqual(intake.payload[CursorHookPayload.digestKey] as? String, "abc123")
        XCTAssertEqual(intake.payload["_remote_host_id"] as? String, "devbox")
    }

    /// Cursor never takes the island's answer: not held, nothing printed.
    func testCursorPermissionIsNeverHeld() throws {
        let intake = try interpret([
            "hook_event_name": "PermissionRequest",
            "session_id": "conv-2",
            "cursor_version": "3.25.9",
            "question": "Run it?",
            "_edge": remoteEdge(source: "claude"),
        ])
        XCTAssertTrue(intake.isPermission)
        XCTAssertFalse(intake.waitsForAnswer)
        XCTAssertNil(intake.stdout(forAnswer: Data(#"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#.utf8)))
    }

    func testBlankCursorVersionStaysClaude() throws {
        let intake = try interpret([
            "hook_event_name": "Stop",
            "session_id": "sess-2",
            "cursor_version": "  ",
            "_edge": remoteEdge(source: "claude"),
        ])
        XCTAssertEqual(intake.payload["_source"] as? String, "claude")
    }

    /// A declared source is the hook's, whatever the payload says.
    func testOtherRemoteSourcesAreDeclared() throws {
        for source in ["codex", "qoder", "codebuddy", "traecli", "my-custom-cli"] {
            let intake = try interpret([
                "hook_event_name": "Stop",
                "session_id": "s-\(source)",
                "_edge": remoteEdge(source: source),
            ])
            XCTAssertEqual(intake.payload["_source"] as? String, source)
            XCTAssertNil(intake.payload["_via_plugin"])
        }
    }

    /// Claude Code's hook with a `_source` the island does not support: the
    /// bridge leaves it (and the island drops the event); so does the edge,
    /// rather than stamp Claude over it. With no `_source`, both mean Claude.
    func testEdgeAndBridgeAgreeOnAnUnsupportedPayloadSource() throws {
        for payloadSource: Any in ["myagent", ""] {
            let stdin: [String: Any] = [
                "hook_event_name": "UserPromptSubmit",
                "session_id": "s-2",
                "cwd": "/work",
                "_source": payloadSource,
            ]
            let bridge = try XCTUnwrap(HookIntake(stdin: stdin, facts: HookIntake.Facts(parentPID: 1234)))
            var delivered = stdin
            delivered["_edge"] = remoteEdge(source: "claude")
            let edge = try interpret(delivered)
            XCTAssertEqual(edge.payload["_source"] as? String, bridge.payload["_source"] as? String, "\(payloadSource)")
            XCTAssertEqual(edge.payload["_source"] as? String, payloadSource as? String)
            XCTAssertNil(edge.source)
        }

        let unnamed = try interpret([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s-3",
            "_edge": remoteEdge(source: "claude"),
        ])
        XCTAssertEqual(unnamed.payload["_source"] as? String, "claude")
    }

    /// The remote OpenCode plugin pipes its events through the remote hook,
    /// which reports the source and the host for it.
    func testRemoteOpenCodePluginEventIsReadFromTheHooksFacts() throws {
        let intake = try interpret([
            "hook_event_name": "PostToolUse",
            "session_id": "opencode-ses_2",
            "_ppid": 31337,
            "_tty": "/dev/pts/9",
            "_server_port": 4096,
            "cwd": "/home/dev/project",
            "_edge": remoteEdge(source: "opencode"),
        ])
        XCTAssertEqual(intake.payload["_source"] as? String, "opencode")
        XCTAssertEqual(intake.payload["_remote_host_id"] as? String, "devbox")
        XCTAssertEqual(intake.payload["_remote_host_name"] as? String, "Dev Box")
        XCTAssertEqual(intake.payload["_tty"] as? String, "/dev/pts/9")
        XCTAssertNil(intake.payload["_ppid"], "a pid of the remote host is not one of this Mac's")
    }

    /// The plugin before v5 stamped its own `_source` and host: they stand.
    func testOlderRemoteOpenCodePluginKeepsItsFields() throws {
        let intake = try interpret([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "opencode-ses_1",
            "_source": "opencode",
            "_ppid": 31337,
            "_hook_ppid": 31336,
            "_tty": "/dev/pts/9",
            "_remote_host_id": "devbox",
            "_remote_host_name": "Dev Box",
            "cwd": "/home/dev/project",
            "_edge": remoteEdge(source: "opencode"),
        ])
        XCTAssertEqual(intake.payload["_source"] as? String, "opencode")
        XCTAssertNil(intake.payload["_ppid"], "a pid of the remote host is not one of this Mac's")
        XCTAssertNil(intake.payload["_hook_ppid"])
        XCTAssertEqual(intake.payload["_tty"] as? String, "/dev/pts/9")
        XCTAssertEqual(intake.payload["_remote_host_id"] as? String, "devbox")
    }

    /// The remote hook decides on its own whether to wait (no round trip for
    /// the rest) and says so; a hook nobody waits on is never held, whatever
    /// its event name — `hookEventName`, say, which the remote hook does not read.
    func testAHookItsEdgeDoesNotWaitOnIsNeverHeld() throws {
        let intake = try interpret([
            "hookEventName": "PermissionRequest",
            "sessionId": "z1",
            "_edge": remoteEdge(source: "my-cli", extra: ["waits": false]),
        ])
        XCTAssertTrue(intake.isPermission)
        XCTAssertFalse(intake.waitsForAnswer)
        XCTAssertNil(intake.stdout(forAnswer: Data(#"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#.utf8)))

        let waiting = try interpret([
            "hook_event_name": "PermissionRequest",
            "session_id": "z2",
            "_edge": remoteEdge(source: "my-cli", extra: ["waits": true]),
        ])
        XCTAssertTrue(waiting.waitsForAnswer)
    }

    /// The bridge observes its own facts: an `_edge` piped into its stdin is
    /// neither read nor forwarded, so nothing interprets a hook twice.
    func testFactsPipedIntoTheBridgeAreDropped() throws {
        var intake = try XCTUnwrap(HookIntake(
            stdin: [
                "hook_event_name": "Stop",
                "session_id": "s",
                "_edge": ["v": 1, "source": "claude", "host": ["id": "elsewhere", "name": "x"]] as [String: Any],
            ],
            facts: HookIntake.Facts(sourceTag: "codex", parentPID: 4242)
        ))
        intake.addTerminalContext()
        XCTAssertNil(intake.payload[HookEdgeFacts.key])
        XCTAssertEqual(intake.payload["_source"] as? String, "codex")
        XCTAssertEqual(intake.payload["_ppid"] as? Int32, 4242)
        XCTAssertNil(intake.payload["_remote_host_id"])
    }

    func testRemoteHookWithoutSessionIsDropped() throws {
        let delivery = HookEdgeFacts.delivery(
            in: ["hook_event_name": "Stop", "_edge": remoteEdge(source: "codex")]
        )
        guard case .dropped = delivery else {
            return XCTFail("a hook with no session and no process to key it by is dropped")
        }
    }

    /// The event and session aliases are HookIntake's, for edges too.
    func testAliasesApply() throws {
        let intake = try interpret([
            "hookEventName": "PreToolUse",
            "sessionId": "fork-1",
            "transcriptPath": "/home/dev/t.jsonl",
            "_edge": remoteEdge(source: "my-fork"),
        ])
        XCTAssertEqual(intake.payload["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(intake.payload["session_id"] as? String, "fork-1")
        XCTAssertEqual(intake.payload["transcript_path"] as? String, "/home/dev/t.jsonl")
    }

    /// An empty `hook_event_name` is no name — on the bridge and for an edge,
    /// as the remote hook reads it when it decides to wait — so an alias, or
    /// `--event`, names the event.
    func testAnEmptyEventNameIsNoName() throws {
        let bridge = try XCTUnwrap(HookIntake(
            stdin: ["hook_event_name": "", "hookEventName": "Stop", "session_id": "s"],
            facts: HookIntake.Facts(parentPID: 1234)
        ))
        XCTAssertEqual(bridge.eventName, "Stop")
        let tagged = try XCTUnwrap(HookIntake(
            stdin: ["hook_event_name": "", "session_id": "s"],
            facts: HookIntake.Facts(sourceTag: "copilot", eventTag: "sessionStart", parentPID: 1234)
        ))
        XCTAssertEqual(tagged.eventName, "sessionStart")

        let edge = try interpret([
            "hook_event_name": "",
            "event": "PermissionRequest",
            "session_id": "s",
            "_edge": remoteEdge(source: "claude", extra: ["waits": true]),
        ])
        XCTAssertTrue(edge.waitsForAnswer)
        // With nothing else to name it, the event stays as it was sent.
        let unnamed = try interpret(["hook_event_name": "", "session_id": "s", "_edge": remoteEdge(source: "claude")])
        XCTAssertEqual(unnamed.payload["hook_event_name"] as? String, "")
    }

    func testRemoteGeminiAnswerIsPutAsGeminiReadsIt() throws {
        let intake = try interpret([
            "hook_event_name": "BeforeTool",
            "session_id": "gem-1",
            "_edge": remoteEdge(source: "gemini"),
        ])
        XCTAssertTrue(intake.waitsForAnswer)
        XCTAssertEqual(intake.answerFormat, .geminiDecision)
        let answer = intake.stdout(forAnswer: Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"always"}}}"#.utf8))
        XCTAssertEqual(answer.map { String(decoding: $0, as: UTF8.self) }, #"{"decision":"allow"}"#)
    }

    func testRemoteClaudePermissionAnswerIsVerbatim() throws {
        let intake = try interpret([
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-3",
            "tool_name": "Bash",
            "_edge": remoteEdge(source: "claude"),
        ])
        XCTAssertTrue(intake.waitsForAnswer)
        let allow = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        XCTAssertEqual(intake.stdout(forAnswer: allow), allow)
        XCTAssertNil(intake.stdout(forAnswer: Data()))
    }

    /// Hermes's conversation copy never forwards; its store stays the remote
    /// hook's to read (`_hermes_store`), never a path on this Mac.
    func testRemoteHermesNeverPointsAtThisMac() throws {
        let intake = try interpret([
            "hook_event_name": "pre_llm_call",
            "session_id": "20261009_101151_eafbd0",
            "extra": ["user_message": "hi", "conversation_history": [["role": "user", "content": "x"]]],
            "_hermes_store": ["title": "Fix it"],
            "_edge": remoteEdge(source: "hermes", extra: ["env": ["HERMES_HOME": "~/.hermes"]]),
        ])
        XCTAssertNil(intake.payload["_hermes_home"])
        XCTAssertNil((intake.payload["extra"] as? [String: Any])?["conversation_history"])
        XCTAssertEqual((intake.payload["_hermes_store"] as? [String: Any])?["title"] as? String, "Fix it")
        XCTAssertEqual(intake.payload["_source"] as? String, "hermes")
    }

    /// A remote edge's pid is not this Mac's; a remote Grok's transcript is
    /// not on this Mac (no home, no file lookup).
    func testRemoteEdgeIgnoresLocalOnlyFacts() throws {
        let intake = try interpret([
            "hookEventName": "Stop",
            "sessionId": "grok-1",
            "cwd": "/home/dev/project",
            "_edge": remoteEdge(source: "grok", extra: [
                "ppid": 4242,
                "env": ["GROK_SESSION_ID": "grok-1", "GROK_HOME": "~/.grok"],
            ]),
        ])
        XCTAssertNil(intake.payload["_ppid"])
        XCTAssertNil(intake.payload["transcript_path"])
        XCTAssertEqual(intake.payload["_source"] as? String, "grok")
    }

    /// A blank cwd is no cwd: Grok's workspace, else the directory the hook
    /// ran in, stands in for it; with neither, the event has none.
    func testABlankCwdIsNoCwd() throws {
        let grok = try interpret([
            "hookEventName": "Stop",
            "sessionId": "grok-2",
            "cwd": "",
            "workspaceRoot": "/home/dev/grok-project",
            "_edge": remoteEdge(source: "grok", extra: ["env": ["GROK_SESSION_ID": "grok-2"]]),
        ])
        XCTAssertEqual(grok.payload["cwd"] as? String, "/home/dev/grok-project")

        let hooks = try interpret(["hook_event_name": "Stop", "session_id": "s", "cwd": "", "_edge": remoteEdge(source: "codex")])
        XCTAssertEqual(hooks.payload["cwd"] as? String, "/home/dev/project")

        var noCwd = remoteEdge(source: "codex")
        noCwd.removeValue(forKey: "cwd")
        let none = try interpret(["hook_event_name": "Stop", "session_id": "s", "cwd": " ", "_edge": noCwd])
        XCTAssertNil(none.payload["cwd"])
    }

    // MARK: - No edge is this Mac

    /// No edge sends facts from this Mac: the bridge reads its own and drops
    /// an `_edge` piped into it. A `host` that is missing, `null` or not an
    /// object (a string) does not make an edge this Mac's: its `ppid` is
    /// never tracked, and no home or file of this Mac is consulted for it.
    func testAnEdgeWithAMalformedHostIsNotTakenForThisMac() throws {
        for host: Any? in [nil, NSNull(), "devbox", ["id": 7]] {
            var edge: [String: Any] = [
                "v": 1,
                "source": "codex",
                "ppid": 4242,
                "cwd": "/Users/u/project",
                "env": [
                    "TERM_PROGRAM": "iTerm.app",
                    "TMUX": "/tmp/tmux-501/default,1,0",
                    "TMUX_PANE": "%3",
                    "UNRELATED_SECRET": "not read",
                ],
                "tmux_client_tty": "/dev/ttys004",
            ]
            edge["host"] = host
            let label = String(describing: host)
            let facts = HookEdgeFacts.facts(from: edge)
            XCTAssertNil(facts.parentPID, label)
            XCTAssertNotNil(facts.remoteHost, label)
            XCTAssertNil(facts.homeDirectory(), label)
            XCTAssertFalse(facts.fileExists("/"), label)

            let intake = try interpret(["hook_event_name": "UserPromptSubmit", "session_id": "s-1", "prompt": "hi", "_edge": edge])
            XCTAssertNil(intake.payload["_ppid"], label)
            XCTAssertNil(intake.payload["_remote_host_id"], "no host to name: \(label)")
            // The facts it did send are still read.
            XCTAssertEqual(intake.payload["_source"] as? String, "codex", label)
            XCTAssertEqual(intake.payload["_term_app"] as? String, "iTerm.app", label)
            XCTAssertEqual(intake.payload["_tmux_pane"] as? String, "%3", label)
            XCTAssertEqual(intake.payload["_tmux_client_tty"] as? String, "/dev/ttys004", label)
            XCTAssertEqual(intake.payload["cwd"] as? String, "/Users/u/project", label)
            XCTAssertFalse(intake.facts.environment.keys.contains("UNRELATED_SECRET"), label)
        }
    }

    /// Without a pid, an edge's hook that names no session cannot be keyed by
    /// its agent's process: it is dropped, not filed under a pid of this Mac.
    func testAnEdgesSessionIsNeverMadeUpFromAPid() {
        let delivery = HookEdgeFacts.delivery(
            in: ["hook_event_name": "Stop", "_edge": ["v": 1, "source": "codex", "ppid": 4242] as [String: Any]]
        )
        guard case .dropped = delivery else {
            return XCTFail("an edge's hook with no session is dropped")
        }
    }

    func testSkipAndGrokImportsAreDropped() {
        for env: [String: String] in [["CODEISLAND_SKIP": "1"], ["GROK_SESSION_ID": "g"]] {
            let delivery = HookEdgeFacts.delivery(
                in: ["hook_event_name": "Stop", "session_id": "s", "_edge": remoteEdge(source: "claude", extra: ["env": env])]
            )
            guard case .dropped = delivery else {
                return XCTFail("\(env) should drop the hook")
            }
        }
    }

    /// Fields are added without a new version; another version is read for
    /// the fields this island knows.
    func testOtherVersionsAreReadForKnownFields() throws {
        var edge = remoteEdge(source: "codex")
        edge["v"] = 2
        edge["something_new"] = ["x": 1]
        let intake = try interpret(["hook_event_name": "Stop", "session_id": "s", "_edge": edge])
        XCTAssertEqual(intake.payload["_source"] as? String, "codex")
    }

    func testPayloadsWithoutFactsAreNotRead() {
        XCTAssertNil(HookEdgeFacts.delivery(in: ["hook_event_name": "Stop", "session_id": "s", "_source": "claude"]))
        XCTAssertNil(HookEdgeFacts.delivery(in: ["hook_event_name": "Stop", "session_id": "s", "_edge": "not an object"]))
        XCTAssertFalse(HookEdgeFacts.mayCarryFacts(Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8)))
        XCTAssertTrue(HookEdgeFacts.mayCarryFacts(Data(#"{"_edge":{"v":1}}"#.utf8)))
    }
}
