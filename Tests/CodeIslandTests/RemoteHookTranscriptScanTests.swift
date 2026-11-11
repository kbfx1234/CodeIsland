import XCTest
@testable import CodeIsland

/// The remote hook enriches events with the latest user / assistant text from the
/// session transcript. It read only top-level `role` / `content`, but Claude Code
/// rows nest the chat message under `message`, so on a real remote host it never
/// found anything. These tests run the shipped codeisland-remote-hook.py against
/// realistic Claude Code transcript rows in a sandbox $HOME.
final class RemoteHookTranscriptScanTests: XCTestCase {
    private var sandboxHome: URL!
    private var hookURL: URL!

    private let sessionId = "8f2c4c1e-0000-4000-8000-000000000271"
    private let cwd = "/work/proj"

    override func setUpWithError() throws {
        sandboxHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
        let source = try XCTUnwrap(RemoteInstaller.remoteHookSource(), "remote hook resource missing")
        hookURL = sandboxHome.appendingPathComponent("codeisland-remote-hook.py")
        try Data(source.utf8).write(to: hookURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandboxHome)
    }

    /// Rows as Claude Code writes them (trimmed to the keys that matter, plus the
    /// envelope noise a real file carries).
    private let claudeRows: [String] = [
        #"{"type":"file-history-snapshot","messageId":"m0","snapshot":{"trackedFileBackups":{}},"isSnapshotUpdate":false}"#,
        #"{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/work/proj","sessionId":"s","version":"2.1.0","type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"},"isMeta":true,"uuid":"u0"}"#,
        #"{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/work/proj","sessionId":"s","version":"2.1.0","type":"user","message":{"role":"user","content":"Fix the login bug"},"uuid":"u1","timestamp":"2026-09-23T02:00:00.000Z"}"#,
        #"{"parentUuid":"u1","type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"Look at the handler first.","signature":"sig"},{"type":"text","text":"Looking at the login handler."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/work/proj/login.py"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":20}},"uuid":"a1"}"#,
        #"{"parentUuid":"a1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"def login(): ..."}]},"toolUseResult":{"type":"text"},"uuid":"u2"}"#,
        #"{"parentUuid":"u2","type":"attachment","attachment":{"type":"todo","content":[]},"uuid":"x1"}"#,
        #"{"parentUuid":"x1","type":"assistant","message":{"id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Fixed: the session cookie is refreshed on login."},{"type":"text","text":"Run the tests to confirm."}]},"uuid":"a2"}"#,
        #"{"type":"summary","summary":"Login bug fix","leafUuid":"a2"}"#,
        #"{"type":"last-prompt","lastPrompt":"Fix the login bug","sessionId":"s"}"#,
    ]

    private func writeClaudeTranscript(_ rows: [String]) throws {
        let dir = sandboxHome.appendingPathComponent(".claude/projects/-work-proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((rows.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("\(sessionId).jsonl"))
    }

    /// Runs `code` with the hook imported as `hook` and returns its JSON output.
    private func runDriver(_ code: String, stdin: String = "") throws -> [String: Any] {
        let driver = """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        SESSION_ID, CWD = sys.argv[2], sys.argv[3]
        \(code)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, sessionId, cwd]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandboxHome.path
        environment["CODEISLAND_SOURCE"] = "claude"
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        process.environment = environment

        let input = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "hook driver failed: \(err)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any], "no JSON from driver")
    }

    private func scan() throws -> [String: Any] {
        try runDriver("print(json.dumps(hook._scan_claude_jsonl(SESSION_ID, CWD)))")
    }

    func testNestedClaudeRowsYieldLatestUserAndAssistantText() throws {
        try writeClaudeTranscript(claudeRows)

        let extras = try scan()

        // Latest real prompt: the isMeta command row and the tool_result row
        // (no text block) must not replace it.
        XCTAssertEqual(extras["last_user_message"] as? String, "Fix the login bug")
        // Every text block of the latest assistant row, newline-joined like the
        // Mac-side JSONLTailer.extractText; thinking / tool_use blocks excluded.
        XCTAssertEqual(
            extras["last_assistant_message"] as? String,
            "Fixed: the session cookie is refreshed on login.\nRun the tests to confirm."
        )
    }

    /// Parity with the Mac: Claude sessions are titled from custom-title /
    /// ai-title records, never from the first prompt or a `summary` row.
    func testNestedClaudeRowsDoNotInventASessionTitle() throws {
        try writeClaudeTranscript(claudeRows)

        let extras = try scan()

        XCTAssertTrue(extras["session_title"] is NSNull, "unexpected title: \(String(describing: extras["session_title"]))")
    }

    /// The older top-level shape still works exactly as before, title included.
    func testLegacyTopLevelRowsStillScan() throws {
        try writeClaudeTranscript([
            #"{"role":"user","content":"hello"}"#,
            #"{"type":"summary","content":"Legacy title"}"#,
            #"{"role":"user","content":"second prompt"}"#,
            #"{"role":"assistant","content":"hi there"}"#,
            #"["not", "an", "object"]"#,
        ])

        let extras = try scan()

        XCTAssertEqual(extras["session_title"] as? String, "Legacy title")
        XCTAssertEqual(extras["last_user_message"] as? String, "second prompt")
        XCTAssertEqual(extras["last_assistant_message"] as? String, "hi there")
    }

    /// End to end through `main()`: a Stop event arriving without
    /// `last_assistant_message` gets it from the transcript, and a field Claude
    /// Code did send is never overwritten.
    func testStopEventIsEnrichedFromNestedTranscript() throws {
        try writeClaudeTranscript(claudeRows)
        let capture = """
        sent = []
        hook._send_event = lambda payload, *_: sent.append(payload)
        hook._get_tty = lambda: None
        hook.main()
        print(json.dumps(sent[0]))
        """

        let stop = try runDriver(capture, stdin: #"{"hook_event_name":"Stop","session_id":"\#(sessionId)","cwd":"/work/proj"}"#)
        XCTAssertEqual(
            stop["last_assistant_message"] as? String,
            "Fixed: the session cookie is refreshed on login.\nRun the tests to confirm."
        )
        XCTAssertEqual(stop["last_user_message"] as? String, "Fix the login bug")

        let sent = try runDriver(capture, stdin: #"{"hook_event_name":"Stop","session_id":"\#(sessionId)","cwd":"/work/proj","last_assistant_message":"from Claude Code"}"#)
        XCTAssertEqual(sent["last_assistant_message"] as? String, "from Claude Code")
    }
}
