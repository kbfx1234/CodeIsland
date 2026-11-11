import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The socket the hook's host has on the island: requests there are its own.
private let buildBox = HookOrigin.remoteHost(id: "host-1", name: "Build Box")

/// The remote hook sends facts (`_edge`) and HookServer interprets them with
/// HookIntake, the bridge's interpretation. These run the shipped
/// codeisland-remote-hook.py's `main()` against a throwaway socket, hand what
/// it sends to `HookServer.intake`, and send the island's answer back the
/// way HookServer would.
@MainActor
final class RemoteHookEdgeFactsTests: XCTestCase {
    private var sandbox: URL!
    private var hookURL: URL!
    private var socketPath: String!
    /// Of the last ``runHook``: whether the stand-in island could still hand
    /// the hook its reply, and how long the hook's `main()` took.
    private var lastReplyDelivered: Bool?
    private var lastHookSeconds: Double = 0

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let source = try XCTUnwrap(RemoteInstaller.remoteHookSource(), "remote hook resource missing")
        hookURL = sandbox.appendingPathComponent("codeisland-remote-hook.py")
        try Data(source.utf8).write(to: hookURL)
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        socketPath = "/tmp/ci-re-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Runs the hook's `main()` on `stdin` as CODEISLAND_SOURCE=`source`; the
    /// stand-in island answers `reply`, `replyDelay` seconds after the hook's
    /// EOF. Returns the raw bytes the hook sent (nil: it sent nothing) and
    /// what it printed.
    private func runHook(
        source: String,
        stdin: String,
        reply: Data = Data(),
        replyDelay: Double = 0
    ) throws -> (sent: Data?, stdout: String) {
        let driver = """
        import base64, importlib.util, io, json, os, socket, sys, threading, time
        hook_path, socket_path, stdin_text, reply = sys.argv[1], sys.argv[2], sys.argv[3], base64.b64decode(sys.argv[4])
        reply_delay = float(sys.argv[5])
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(socket_path)
        server.listen(1)
        server.settimeout(5)
        received = {}
        def serve():
            try:
                conn, _ = server.accept()
            except OSError:
                return
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            received["payload"] = base64.b64encode(data).decode()
            time.sleep(reply_delay)
            if reply:
                try:
                    conn.sendall(reply)
                    received["delivered"] = True
                except OSError:
                    received["delivered"] = False
            conn.close()
        thread = threading.Thread(target=serve)
        thread.start()
        spec = importlib.util.spec_from_file_location("hook", hook_path)
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        hook._get_tty = lambda: "/dev/pts/7"
        sys.stdin = io.TextIOWrapper(io.BytesIO(stdin_text.encode("utf-8")), encoding="utf-8")
        printed = io.StringIO()
        real_stdout, sys.stdout = sys.stdout, printed
        started = time.monotonic()
        try:
            hook.main()
        finally:
            sys.stdout = real_stdout
        seconds = time.monotonic() - started
        thread.join(6)
        print(json.dumps({"sent": received.get("payload"), "stdout": printed.getvalue(),
                          "delivered": received.get("delivered"), "seconds": seconds}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, socketPath, stdin, reply.base64EncodedString(), String(replyDelay)]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandbox.path
        environment["CODEISLAND_SOCKET_PATH"] = socketPath
        environment["CODEISLAND_SOURCE"] = source
        environment["CODEISLAND_REMOTE_HOST_ID"] = "host-1"
        environment["CODEISLAND_REMOTE_HOST_NAME"] = "Build Box"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "hook driver failed: \(err)")
        try? FileManager.default.removeItem(atPath: socketPath)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        let sent = (result["sent"] as? String).flatMap { Data(base64Encoded: $0) }
        lastReplyDelivered = result["delivered"] as? Bool
        lastHookSeconds = result["seconds"] as? Double ?? 0
        return (sent, result["stdout"] as? String ?? "")
    }

    private func intake(_ sent: Data?, file: StaticString = #filePath, line: UInt = #line) throws -> (event: [String: Any], intake: HookIntake) {
        let sent = try XCTUnwrap(sent, "the hook sent nothing", file: file, line: line)
        guard case .route(let routed, let edge?) = HookServer.intake(sent, origin: buildBox) else {
            XCTFail("the island did not read the hook's facts", file: file, line: line)
            throw XCTSkip("no intake")
        }
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: routed) as? [String: Any], file: file, line: line)
        return (event, edge)
    }

    // MARK: - Facts out, the bridge's reading in

    func testRemoteEventIsReadLikeTheBridgesWouldBe() throws {
        let stdin = #"{"hook_event_name":"UserPromptSubmit","session_id":"sess-1","cwd":"/work/proj","prompt":"Fix it"}"#
        let (sent, stdout) = try runHook(source: "claude", stdin: stdin, reply: Data("{}".utf8))
        XCTAssertEqual(stdout, "", "nothing waits on a prompt, nothing is printed")

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent)) as? [String: Any])
        let edge = try XCTUnwrap(raw["_edge"] as? [String: Any])
        XCTAssertEqual(edge["v"] as? Int, 1)
        XCTAssertEqual(edge["source"] as? String, "claude")
        XCTAssertEqual(edge["tty"] as? String, "/dev/pts/7")
        XCTAssertEqual((edge["host"] as? [String: Any])?["id"] as? String, "host-1")
        XCTAssertEqual(edge["stdin_sha256"] as? String, CursorHookPayload.deliveryDigest(of: Data(stdin.utf8)))
        XCTAssertEqual(edge["waits"] as? Bool, false)
        XCTAssertNil(edge["env"], "a remote hook sends no environment")
        XCTAssertNil(edge["ppid"], "nor a process id")
        for key in ["_source", "_tty"] {
            XCTAssertNil(raw[key], "\(key) is the island's to derive")
        }
        // Named for islands that predate `_edge` too.
        XCTAssertEqual(raw["_remote_host_id"] as? String, "host-1")
        XCTAssertEqual(raw["_remote_host_name"] as? String, "Build Box")

        let (event, intake) = try intake(sent)
        XCTAssertEqual(event["_source"] as? String, "claude")
        XCTAssertEqual(event["_remote_host_id"] as? String, "host-1")
        XCTAssertEqual(event["_remote_host_name"] as? String, "Build Box")
        XCTAssertEqual(event["_tty"] as? String, "/dev/pts/7")
        XCTAssertEqual(event["session_id"] as? String, "sess-1")
        XCTAssertEqual(event["cwd"] as? String, "/work/proj")
        XCTAssertNil(event["_edge"])
        XCTAssertNil(event["_ppid"])
        XCTAssertFalse(intake.waitsForAnswer)
    }

    /// A blocking request: the island's answer goes back as the agent reads
    /// it, and the hook prints it.
    func testPermissionAnswerReachesTheAgent() throws {
        let stdin = #"{"hook_event_name":"PermissionRequest","session_id":"sess-2","cwd":"/work/proj","tool_name":"Bash","tool_input":{"command":"make"}}"#
        let (sent, _) = try runHook(source: "claude", stdin: stdin)
        let (_, intake) = try intake(sent)
        XCTAssertTrue(intake.waitsForAnswer)
        let allow = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        let answer = try XCTUnwrap(intake.stdout(forAnswer: allow))

        let (_, printed) = try runHook(source: "claude", stdin: stdin, reply: answer)
        XCTAssertEqual(printed, String(decoding: allow, as: UTF8.self) + "\n")
    }

    /// Gemini reads `{"decision": …}`; the island now puts the answer that
    /// way for the remote hook too, as the bridge does for the local one.
    func testGeminiAnswerIsPutOnTheIsland() throws {
        let stdin = #"{"hook_event_name":"BeforeTool","session_id":"gem-1","tool_name":"run_shell_command"}"#
        let (sent, _) = try runHook(source: "gemini", stdin: stdin)
        let (event, intake) = try intake(sent)
        XCTAssertEqual(event["_source"] as? String, "gemini")
        let deny = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        let answer = try XCTUnwrap(intake.stdout(forAnswer: deny))
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), #"{"decision":"deny"}"#)

        let (_, printed) = try runHook(source: "gemini", stdin: stdin, reply: answer)
        XCTAssertEqual(printed, #"{"decision":"deny"}"# + "\n")
    }

    /// The island answers a hook it does not hold at once and with nothing;
    /// the hook then prints nothing.
    func testNothingIsPrintedForAnEmptyAnswer() throws {
        let stdin = #"{"hook_event_name":"PermissionRequest","session_id":"conv-1","cursor_version":"3.25.9","question":"Run?"}"#
        let (sent, printed) = try runHook(source: "claude", stdin: stdin, reply: Data())
        XCTAssertEqual(printed, "")
        guard case .answerNothing = HookServer.intake(try XCTUnwrap(sent), origin: buildBox) else {
            return XCTFail("a Cursor hook is not held on the island")
        }
    }

    /// A hook with no session id used to stop at the remote hook; it now
    /// reaches the island, which drops it — without anyone waiting on it.
    func testHookWithoutSessionIsDroppedOnTheIsland() throws {
        let (sent, printed) = try runHook(source: "claude", stdin: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(printed, "")
        guard case .answerNothing = HookServer.intake(try XCTUnwrap(sent), origin: buildBox) else {
            return XCTFail("a hook with no session is dropped")
        }
    }

    /// A hook nobody waits on reads the island's reply all the same: an older
    /// island, which accepted connections on its main thread, lost the event
    /// of a hook that had closed before it got there. It prints nothing.
    func testAHookNobodyWaitsOnStaysForTheIslandsReply() throws {
        let stdin = #"{"hook_event_name":"Stop","session_id":"sess-1","cwd":"/work/proj"}"#
        let (_, printed) = try runHook(source: "claude", stdin: stdin, reply: Data("{}".utf8), replyDelay: 0.3)
        XCTAssertEqual(lastReplyDelivered, true, "the hook closed before the island answered")
        XCTAssertEqual(printed, "", "nothing waits on a Stop, nothing is printed")
    }

    /// …but not for long: an island that does not answer holds the agent no
    /// more than a couple of seconds.
    func testAHookNobodyWaitsOnDoesNotWaitLongForTheReply() throws {
        let stdin = #"{"hook_event_name":"Stop","session_id":"sess-1","cwd":"/work/proj"}"#
        let (sent, printed) = try runHook(source: "claude", stdin: stdin, reply: Data("{}".utf8), replyDelay: 3.5)
        XCTAssertNotNil(sent)
        XCTAssertEqual(printed, "")
        XCTAssertEqual(lastReplyDelivered, false, "the hook was still waiting after 3.5 s")
        XCTAssertLessThan(lastHookSeconds, 3.4)
    }

    /// A tool step fires on every tool call while the agent waits for its hook
    /// to exit, so it leaves as soon as the event is sent: no round trip over
    /// the SSH link per tool call. The island keeps the event of a hook that
    /// closed at once.
    func testAToolStepDoesNotStayForTheReply() throws {
        for event in ["PreToolUse", "PostToolUse", "pre_tool_use", "post_tool_call"] {
            let stdin = #"{"hook_event_name":"\#(event)","session_id":"sess-1","cwd":"/work/proj","tool_name":"Bash"}"#
            let (sent, printed) = try runHook(source: "claude", stdin: stdin, reply: Data("{}".utf8), replyDelay: 1.5)
            XCTAssertNotNil(sent, event)
            XCTAssertEqual(printed, "", event)
            XCTAssertLessThan(lastHookSeconds, 1.0, "\(event) stayed for the island's reply")
        }
    }

    /// HookServer's byte probes read paths as written (`/.cursor/` sends a
    /// Cursor Task's hook to Agent Sub-Sessions): the interpreted payload keeps
    /// its slashes unescaped, as the remote hook used to send them.
    func testInterpretedPayloadKeepsPathsAsWritten() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "task-1",
            "transcript_path": "/home/u/.cursor/projects/p/agent-transcripts/chat-1/subagents/task-1.jsonl",
            "_edge": ["v": 1, "source": "claude", "waits": false, "host": ["id": "h", "name": "h"]] as [String: Any],
        ]
        guard case .route(let routed, _?) = HookServer.intake(try JSONSerialization.data(withJSONObject: payload), origin: buildBox) else {
            return XCTFail("the island did not read the hook's facts")
        }
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: routed))
    }

    // MARK: - Agreement and compatibility

    /// The remote hook decides on its own whether to wait for an answer (no
    /// round trip for the rest). On the names it reads it must wait exactly
    /// when HookIntake would hold the hook; on a spelling it does not read,
    /// the island, told nobody waits, must not hold the hook either.
    func testRemoteHookWaitsExactlyWhenTheIslandHoldsTheHook() throws {
        // Every name EventNormalizer maps, and a few it passes through.
        let names = [
            "beforeSubmitPrompt", "beforeShellExecution", "afterShellExecution", "beforeReadFile",
            "afterFileEdit", "beforeMCPExecution", "afterMCPExecution", "afterAgentThought",
            "afterAgentResponse", "stop", "BeforeTool", "AfterTool", "BeforeAgent", "AfterAgent",
            "sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse",
            "errorOccurred", "agentSpawn", "userPromptSubmit", "session_start", "session_end",
            "user_prompt_submit", "pre_tool_use", "post_tool_use", "post_tool_use_failure",
            "permission_request", "permission_denied", "stop_failure", "StopFailure",
            "subagent_start", "subagent_stop", "pre_compact", "post_compact", "notification",
            "pre_tool_call", "post_tool_call", "pre_llm_call", "post_llm_call", "on_session_start",
            "on_session_end", "on_session_finalize", "on_session_reset", "TaskStart", "TaskResume",
            "TaskComplete", "TaskCancel",
            "PermissionRequest", "Notification", "PreToolUse", "PostToolUse", "Stop", "SessionStart",
            "SessionEnd", "UserPromptSubmit", "SubagentStop", "PreCompact", "Elicitation",
        ]
        var payloads: [[String: Any]] = []
        for name in names {
            payloads.append(["hook_event_name": name, "session_id": "s"])
            payloads.append(["hook_event_name": name, "session_id": "s", "question": "Which one?"])
            payloads.append(["hook_event_name": name, "session_id": "s", "question": ["not": "a string"]])
        }
        payloads.append(["event": "PermissionRequest", "session_id": "s"])
        // An empty name is no name, on both sides.
        payloads.append(["hook_event_name": "", "event": "PermissionRequest", "session_id": "s"])
        payloads.append(["hook_event_name": "", "event": "Notification", "session_id": "s", "question": "Which one?"])
        payloads.append(["hook_event_name": "", "event": "Stop", "session_id": "s"])
        // Spellings the remote hook does not read.
        let unread: [[String: Any]] = [
            ["hookEventName": "PermissionRequest", "sessionId": "s"],
            ["eventName": "PermissionRequest", "session_id": "s"],
            ["hookEventName": "Notification", "session_id": "s", "question": "Which one?"],
            ["hook_event_name": "", "hookEventName": "PermissionRequest", "session_id": "s"],
        ]
        payloads += unread

        let json = String(decoding: try JSONSerialization.data(withJSONObject: payloads), as: UTF8.self)
        let driver = """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        print(json.dumps([hook._waits_for_answer(p) for p in json.loads(sys.argv[2])]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, json]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let waits = try XCTUnwrap(JSONSerialization.jsonObject(with: stdout.fileHandleForReading.readDataToEndOfFile()) as? [Bool])
        XCTAssertEqual(waits.count, payloads.count)

        for (index, (payload, edgeWaits)) in zip(payloads, waits).enumerated() {
            // What HookIntake decides on its own.
            var delivered = payload
            delivered["_edge"] = ["v": 1, "source": "claude", "host": ["id": "h", "name": "h"]] as [String: Any]
            guard case .interpreted(let intake)? = HookEdgeFacts.delivery(in: delivered) else {
                XCTFail("\(payload): dropped")
                continue
            }
            if index < payloads.count - unread.count {
                XCTAssertEqual(edgeWaits, intake.waitsForAnswer, "\(payload)")
                continue
            }
            XCTAssertFalse(edgeWaits, "\(payload)")
            XCTAssertTrue(intake.waitsForAnswer, "\(payload)")
            // What the island does once the edge says it does not wait.
            delivered["_edge"] = ["v": 1, "source": "claude", "waits": edgeWaits, "host": ["id": "h", "name": "h"]] as [String: Any]
            guard case .answerNothing = HookServer.intake(try JSONSerialization.data(withJSONObject: delivered), origin: buildBox) else {
                XCTFail("\(payload): held although nobody waits on it")
                continue
            }
        }
    }

    /// A Mac on an island that predates `_edge` reads the top level only. The
    /// hook names its host there, so such an island files the session under
    /// it (not as a local one), and the agent it was installed for; and it
    /// never sends a pid of its host — the remote OpenCode plugin before v6
    /// put its own in `_ppid`, which an island without the host would have
    /// monitored, and could have signalled, as a local process.
    func testRemoteHookStillNamesItsHostForIslandsThatPredateEdgeFacts() throws {
        let stdin = #"{"session_id":"opencode-ses_1","hook_event_name":"UserPromptSubmit","cwd":"/work/proj","prompt":"hi","_ppid":4242,"_hook_ppid":4241,"_tty":"/dev/pts/3"}"#
        let (sent, _) = try runHook(source: "opencode", stdin: stdin)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent)) as? [String: Any])
        XCTAssertEqual(raw["_remote_host_id"] as? String, "host-1")
        XCTAssertEqual(raw["_remote_host_name"] as? String, "Build Box")
        XCTAssertEqual(raw["_source"] as? String, "opencode")
        XCTAssertNil(raw["_ppid"])
        XCTAssertNil(raw["_hook_ppid"])
        XCTAssertEqual(raw["_tty"] as? String, "/dev/pts/3", "the plugin's own terminal stays")

        let (event, _) = try intake(sent)
        XCTAssertEqual(event["_remote_host_id"] as? String, "host-1")
        XCTAssertEqual(event["_source"] as? String, "opencode")
        XCTAssertNil(event["_ppid"])

        // Claude Code's hook, which Cursor runs too: the island decides the
        // source from the payload, so the hook names none.
        let (claudeSent, _) = try runHook(source: "claude", stdin: #"{"session_id":"s","hook_event_name":"Stop"}"#)
        let claude = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(claudeSent)) as? [String: Any])
        XCTAssertNil(claude["_source"])
        XCTAssertEqual(claude["_remote_host_id"] as? String, "host-1")

        // A host the payload names stands, as an older island reads it; the
        // island takes the host from the socket the hook reached.
        let (namedSent, _) = try runHook(source: "codex", stdin: #"{"session_id":"s","hook_event_name":"Stop","_remote_host_id":"other","_source":"codex"}"#)
        let named = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(namedSent)) as? [String: Any])
        XCTAssertEqual(named["_remote_host_id"] as? String, "other")
        XCTAssertEqual(named["_source"] as? String, "codex")
        let (namedEvent, _) = try intake(namedSent)
        XCTAssertEqual(namedEvent["_remote_host_id"] as? String, "host-1")
        XCTAssertEqual(namedEvent["_remote_host_name"] as? String, "Build Box")
    }

    /// A blank cwd meets the per-host cwd allow-list (#240), which drops a
    /// remote event without one: the v4 OpenCode plugin, still loaded in a
    /// running OpenCode, sends `"cwd": ""` when PWD is unset. The directory the
    /// hook ran in stands in for it, as the remote hook put it in its place
    /// before facts.
    func testBlankRemoteCwdStillPassesTheHostsCwdFilter() throws {
        for blank in ["", "  "] {
            let payload: [String: Any] = [
                "hook_event_name": "UserPromptSubmit",
                "session_id": "ses_1",
                "cwd": blank,
                "prompt": "hi",
                "_edge": ["v": 1, "source": "opencode", "cwd": "/home/dev/proj",
                          "host": ["id": "host-1", "name": "Build Box"], "waits": false] as [String: Any],
            ]
            guard case .route(let routed, _) = HookServer.intake(try JSONSerialization.data(withJSONObject: payload), origin: buildBox) else {
                return XCTFail("not routed")
            }
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: routed) as? [String: Any])
            XCTAssertEqual(event["cwd"] as? String, "/home/dev/proj", "cwd \"\(blank)\"")
            XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(
                cwd: event["cwd"] as? String,
                workspaceRoots: event["workspace_roots"] as? [String],
                filterCSV: "/home/dev/proj"
            ))
        }
    }

    /// Remote hooks installed before facts existed (0.3.1) keep interpreting
    /// their hooks themselves; the island takes their payload as it is, filed
    /// under the host whose socket it came in on.
    func testPayloadsFromOlderRemoteHooksPassUntouched() throws {
        let legacy = Data(#"{"hook_event_name":"Stop","session_id":"sess-9","cwd":"/work/proj","_source":"claude","_remote_host_id":"host-1","_remote_host_name":"Build Box","_tty":"/dev/pts/7","last_assistant_message":"Done."}"#.utf8)
        guard case .route(let routed, let edge) = HookServer.intake(legacy, origin: buildBox) else {
            return XCTFail("a legacy payload is routed")
        }
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? NSDictionary)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: routed) as? NSDictionary), sent)
        XCTAssertNil(edge)
    }

    func testVersionMatchesTheInstaller() throws {
        let source = try XCTUnwrap(RemoteInstaller.remoteHookSource())
        let script = RemoteInstaller.configureRemoteHooksScript(host: RemoteHost(id: "h", name: "h", host: "example.com"))
        let version = try XCTUnwrap(source.split(separator: "\n").first { $0.hasPrefix("VERSION = ") })
        XCTAssertTrue(script.contains(String(version).replacingOccurrences(of: "VERSION = ", with: "version = ")), String(version))
    }
}
