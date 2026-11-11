import XCTest
@testable import CodeIsland

/// #271 — the remote hook looks up Claude transcripts under the config dir Claude
/// Code actually uses. The hook runs as a child of Claude Code, so
/// $CLAUDE_CONFIG_DIR in its environment is authoritative. These tests load the
/// shipped codeisland-remote-hook.py and call its resolver against a sandbox $HOME.
final class RemoteHookClaudeConfigDirTests: XCTestCase {
    private var sandboxHome: URL!
    private var hookURL: URL!

    private let sessionId = "sess-271"
    private let cwd = "/work/proj"
    /// `_claude_jsonl_path`'s encoding of `cwd`.
    private let projectDir = "-work-proj"

    override func setUpWithError() throws {
        sandboxHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
        let source = try XCTUnwrap(RemoteInstaller.remoteHookSource(), "remote hook resource missing")
        hookURL = sandboxHome.appendingPathComponent("codeisland-remote-hook.py")
        try Data(source.utf8).write(to: hookURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandboxHome)
    }

    private struct Resolution: Decodable {
        let dir: String
        let jsonl: String?
    }

    /// Imports the hook as a module (its `main()` is behind `__name__` guard) and
    /// reports what it resolves for `sessionId` / `cwd`.
    private func resolve(claudeConfigDir: String?) throws -> Resolution {
        let driver = """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        print(json.dumps({"dir": hook._claude_config_dir(), "jsonl": hook._claude_jsonl_path(sys.argv[2], sys.argv[3])}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, sessionId, cwd]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandboxHome.path
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        if let claudeConfigDir { environment["CLAUDE_CONFIG_DIR"] = claudeConfigDir }
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
        return try JSONDecoder().decode(Resolution.self, from: out)
    }

    /// Writes a transcript for `sessionId` under `<configDir>/projects/`.
    private func writeTranscript(configDir: String) throws -> String {
        let dir = URL(fileURLWithPath: configDir).appendingPathComponent("projects/\(projectDir)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionId).jsonl")
        try Data("{\"role\":\"user\",\"content\":\"hi\"}\n".utf8).write(to: file)
        return file.path
    }

    func testUnsetUsesDotClaude() throws {
        let dotClaude = sandboxHome.path + "/.claude"
        let transcript = try writeTranscript(configDir: dotClaude)

        let resolved = try resolve(claudeConfigDir: nil)

        XCTAssertEqual(resolved.dir, dotClaude)
        XCTAssertEqual(resolved.jsonl, transcript)
    }

    func testSetUsesClaudeConfigDir() throws {
        let custom = sandboxHome.path + "/claude-work"
        let transcript = try writeTranscript(configDir: custom)

        let resolved = try resolve(claudeConfigDir: custom)

        XCTAssertEqual(resolved.dir, custom)
        XCTAssertEqual(resolved.jsonl, transcript)
    }

    /// Authoritative means no fallback: a transcript left in ~/.claude belongs to a
    /// different Claude Code config, not to this session.
    func testSetDoesNotFallBackToDotClaude() throws {
        _ = try writeTranscript(configDir: sandboxHome.path + "/.claude")

        let resolved = try resolve(claudeConfigDir: sandboxHome.path + "/claude-work")

        XCTAssertNil(resolved.jsonl)
    }

    func testTildeIsExpandedAndRelativeIsIgnored() throws {
        XCTAssertEqual(try resolve(claudeConfigDir: "~/claude-work").dir, sandboxHome.path + "/claude-work")
        XCTAssertEqual(try resolve(claudeConfigDir: "claude-work").dir, sandboxHome.path + "/.claude")
        XCTAssertEqual(try resolve(claudeConfigDir: "   ").dir, sandboxHome.path + "/.claude")
    }

    /// ext4/xfs are byte-preserving — the hook must not NFC-normalize the path the
    /// way the macOS-side resolver does. Swift `==` compares canonically, so check bytes.
    func testClaudeConfigDirIsNotUnicodeNormalized() throws {
        let decomposed = sandboxHome.path + "/cafe\u{0301}-claude"
        XCTAssertNotEqual(Array(decomposed.utf8), Array(decomposed.precomposedStringWithCanonicalMapping.utf8))

        let resolved = try resolve(claudeConfigDir: decomposed)

        XCTAssertEqual(Array(resolved.dir.utf8), Array(decomposed.utf8))
    }
}
