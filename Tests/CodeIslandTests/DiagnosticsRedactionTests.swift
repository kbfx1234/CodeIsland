import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A diagnostics zip goes on a public issue: the CLI configs in it keep
/// their shape and hooks without their secrets, and the saved session list
/// says what each session was, not what was said in it. Against files of
/// the test's, never the user's.
final class DiagnosticsRedactionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ci-diag-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func redactedConfig(_ json: String) throws -> String {
        let data = try XCTUnwrap(DiagnosticsRedaction.redactedConfig(Data(json.utf8)))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - CLI configs

    private let claudeSettings = #"""
    {
      "env": {"ANTHROPIC_API_KEY": "sk-ant-api03-SECRET0001", "ANTHROPIC_BASE_URL": "https://SECRET0002.example", "DISABLE_TELEMETRY": "1"},
      "apiKeyHelper": "printf SECRET0003",
      "model": "opus",
      "hooks": {"PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "timeout": 86400,
        "command": "ANTHROPIC_AUTH_TOKEN=SECRET0004 ~/.codeisland/codeisland-hook.sh --api-key SECRET0005"}]}]},
      "mcpServers": {
        "github": {"command": "npx", "args": ["-y", "@mcp/github", "--token", "SECRET0006", "--password=SECRET0007"],
          "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_SECRET0008aaaaaaaaaaaaaaaaaaaa"},
          "headers": {"Authorization": "Bearer SECRET0009", "X-Api-Key": "SECRET0010"}},
        "remote": {"url": "https://alice:SECRET0011@mcp.example/sse"}
      },
      "permissions": {"allow": ["Bash(ls:*)"]},
      "maxTokens": 8192,
      "includeCoAuthoredBy": false
    }
    """#

    func testClaudeSettingsKeepTheirShapeAndHooksButNoSecret() throws {
        let out = try redactedConfig(claudeSettings)
        XCTAssertFalse(out.contains("SECRET"), out)
        // What the report is for stays.
        for kept in [
            "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "DISABLE_TELEMETRY",
            "~/.codeisland/codeisland-hook.sh", "PreToolUse", "86400", "\"opus\"",
            "npx", "@mcp/github", "--token", "mcp.example/sse", "Bash(ls:*)", "8192", "includeCoAuthoredBy",
        ] {
            XCTAssertTrue(out.contains(kept), "\(kept) missing from \(out)")
        }
    }

    func testAnEnvListKeepsItsNamesOnly() throws {
        let out = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(DiagnosticsRedaction.redactedConfig(
                Data(#"{"env": ["FOO=bar", "PLAIN"], "environment": {"A": "b"}}"#.utf8)
            ))) as? [String: Any]
        )
        XCTAssertEqual(out["env"] as? [String], ["FOO=<redacted>", "<redacted>"])
        XCTAssertEqual(out["environment"] as? [String: String], ["A": "<redacted>"])
    }

    func testAConfigWithCommentsIsReadAndOneThatIsNotJSONIsLeftOut() throws {
        let jsonc = """
        {
          // a comment
          "hooks": {"Stop": [{"command": "x", "token": "SECRET-IN-JSONC"}]},
        }
        """
        let out = try redactedConfig(jsonc)
        XCTAssertTrue(out.contains("Stop"), out)
        XCTAssertFalse(out.contains("SECRET"), out)
        XCTAssertNil(DiagnosticsRedaction.redactedConfig(Data("token = SECRET-TOML".utf8)))
    }

    func testSecretsInTextAreReplacedWhereverTheyAre() {
        let secrets = [
            "curl -H 'Authorization: Bearer SECRETabc.def' https://x",
            "OPENAI_API_KEY=sk-proj-SECRETabcdefgh npm start",
            "export GH_TOKEN='SECRET with spaces'",
            "claude --api-key=SECRETkey",
            "git clone https://bob:SECRETpw@git.example/repo.git",
            "key sk-ant-api03-SECRETkeyvalue",
            "ghp_SECRET0123456789abcdefghij",
            "xoxb-SECRET-1234567890",
            "AKIASECRET0123456789",
            "AIzaSECRET-0123456789abcdefghijklmnopqrstu",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SECRETsignature",
            "x-api-key: SECRETheader",
        ]
        for text in secrets {
            let out = DiagnosticsRedaction.redactSecrets(in: text)
            XCTAssertFalse(out.contains("SECRET"), "\(text) → \(out)")
            XCTAssertTrue(out.contains("<redacted>"), "\(text) → \(out)")
        }
        for plain in [
            "npm run build --watch", "Fix the login bug", "~/.codeisland/codeisland-bridge --source codex",
            "wire the my-auth-service module", "rename monkey-key handling",
        ] {
            XCTAssertEqual(DiagnosticsRedaction.redactSecrets(in: plain), plain)
        }
    }

    func testKeysThatNameASecret() {
        for key in ["apiKey", "apiKeyHelper", "api_key", "X-API-Key", "GITHUB_TOKEN", "client_secret", "password",
                    "Authorization", "cookie", "primaryApiKey", "awsCredentials"] {
            XCTAssertTrue(DiagnosticsRedaction.isSecretKey(key), key)
        }
        for key in ["model", "hooks", "command", "keybindings", "monkeyPatch", "matcher", "statusLine"] {
            XCTAssertFalse(DiagnosticsRedaction.isSecretKey(key), key)
        }
    }

    // MARK: - The saved session list

    func testTheSavedSessionListSaysWhatEachSessionWasNotWhatWasSaid() throws {
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/project"
        session.ttyPath = "/dev/ttys004"
        session.lastUserPrompt = String(repeating: "p", count: 80) + "SECRET-PROMPT-TAIL"
        session.lastAssistantMessage = "SECRET-REPLY"
        session.sessionTitle = "SECRET-TITLE"
        session.recap = SessionRecap(text: "SECRET-RECAP", createdAt: Date())
        SessionPersistence.save(["session-1": session], directory: scratch.path)
        let saved = try Data(contentsOf: scratch.appendingPathComponent("sessions.json"))
        // A task list as an older or newer build may have written it.
        var entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        entries[0]["agentTasks"] = ["items": [["id": "t1", "title": "SECRET-TASK", "status": "in_progress"]]]
        entries[0]["someFutureField"] = "SECRET-FUTURE"

        let out = try XCTUnwrap(DiagnosticsRedaction.redactedPersistedSessions(
            JSONSerialization.data(withJSONObject: entries)
        ))
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET"), text)
        let exported = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [[String: Any]]).first
        let entry = try XCTUnwrap(exported)
        XCTAssertEqual(entry["sessionId"] as? String, "session-1")
        XCTAssertEqual(entry["source"] as? String, "claude")
        XCTAssertEqual(entry["cwd"] as? String, "/Users/dev/project")
        XCTAssertEqual(entry["ttyPath"] as? String, "/dev/ttys004")
        XCTAssertNotNil(entry["startTime"] as? String)
        XCTAssertEqual(entry["lastUserPrompt"] as? String, String(repeating: "p", count: 80))
        XCTAssertEqual(entry["lastAssistantMessage"] as? String, "<12 characters>")
        XCTAssertEqual(entry["sessionTitle"] as? String, "<12 characters>")
        let tasks = try XCTUnwrap((entry["agentTasks"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(tasks.first?["status"] as? String, "in_progress")
        XCTAssertEqual(tasks.first?["id"] as? String, "t1")
    }

    func testAPromptPreviewLosesASecretInIt() {
        XCTAssertEqual(
            DiagnosticsRedaction.promptPreview("  use sk-ant-api03-SECRETkeyvalue to call it  "),
            "use <redacted> to call it"
        )
    }

    // MARK: - The export

    func testTheExportWritesTheConfigsRedactedAndNeverAsTheyAre() throws {
        let claude = scratch.appendingPathComponent("settings.json")
        try Data(claudeSettings.utf8).write(to: claude)
        let toml = scratch.appendingPathComponent("hooks.json")
        try Data("token = \"SECRET-NOT-JSON\"".utf8).write(to: toml)
        let sessions = scratch.appendingPathComponent("sessions.json")
        var session = SessionSnapshot()
        session.lastAssistantMessage = "SECRET-REPLY"
        SessionPersistence.save(["s1": session], directory: scratch.path)
        let root = scratch.appendingPathComponent("zip")

        DiagnosticsExporter.writeConfigs(
            [(claude.path, "configs/claude-settings.json"), (toml.path, "configs/codex-hooks.json"),
             (scratch.appendingPathComponent("missing.json").path, "configs/gemini-settings.json")],
            sessionsFile: sessions.path,
            to: root
        )
        let written = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("configs").path).sorted()
        XCTAssertEqual(written, ["claude-settings.json", "codex-hooks.json", "persisted-sessions.json"])
        for name in written {
            let text = try String(contentsOf: root.appendingPathComponent("configs/" + name), encoding: .utf8)
            XCTAssertFalse(text.contains("SECRET"), "\(name): \(text)")
        }
        let note = try String(contentsOf: root.appendingPathComponent("configs/codex-hooks.json"), encoding: .utf8)
        XCTAssertTrue(note.contains("leftOut"), note)
    }

    // MARK: - What Settings says

    func testEveryLanguageSaysWhatTheZipHolds() {
        for (language, table) in L10n.strings {
            let text = table["export_diagnostics_desc"] ?? ""
            XCTAssertTrue(text.contains("80"), "\(language): \(text)")
            XCTAssertTrue(text.contains("env"), "\(language) should say env values are removed: \(text)")
        }
    }
}
