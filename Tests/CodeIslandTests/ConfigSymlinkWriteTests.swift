import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Hook writes through symlinked config files. Multi-account and dotfiles
/// setups link `settings.json` / `hooks.json` / `config.toml` to a shared
/// copy; an atomic replace used to turn the link into a detached regular
/// file on the first write. Everything runs in a temporary directory, with
/// `CODEX_HOME` pointed into it for the primary-root cases; nothing here goes
/// through `installClaudeHooks` (it asks the installed `claude` for its
/// version).
final class ConfigSymlinkWriteTests: XCTestCase {
    private var sandbox: String!
    private var savedCodexHome: String?
    private let fm = FileManager.default

    override func setUpWithError() throws {
        sandbox = fm.temporaryDirectory.appendingPathComponent("config-symlink-writes-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: sandbox + "/dotfiles", withIntermediateDirectories: true)
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    }

    override func tearDownWithError() throws {
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        try? fm.removeItem(atPath: sandbox)
    }

    private func makeDir(_ relative: String, files: [String] = []) throws -> String {
        let path = sandbox + "/" + relative
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        for file in files { XCTAssertTrue(fm.createFile(atPath: path + "/" + file, contents: Data("{}".utf8))) }
        return path
    }

    /// `link` → `sandbox/dotfiles/<name>` holding `contents`; returns the target.
    @discardableResult
    private func linkToDotfile(_ link: String, named name: String, contents: String) throws -> String {
        let target = sandbox + "/dotfiles/" + name
        XCTAssertTrue(fm.createFile(atPath: target, contents: Data(contents.utf8)))
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        return target
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func hooks(inJSONAt path: String) throws -> [String: Any] {
        let data = try XCTUnwrap(fm.contents(atPath: path))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root["hooks"] as? [String: Any] ?? [:]
    }

    // MARK: - Extra roots

    func testCodexExtraRootKeepsItsSymlinkedHooksAndConfigFiles() throws {
        let root = try makeDir("codex-work", files: ["auth.json"])
        let hooksTarget = try linkToDotfile(root + "/hooks.json", named: "codex-hooks.json", contents: "{}\n")
        let configTarget = try linkToDotfile(root + "/config.toml", named: "codex-config.toml", contents: "model = \"o3\"\n")
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .codex, path: root)))

        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: sandbox + "/primary", peers: []), .installed)

        XCTAssertTrue(isSymlink(root + "/hooks.json"), "hooks.json is still the shared link")
        XCTAssertTrue(isSymlink(root + "/config.toml"), "config.toml is still the shared link")
        XCTAssertNotNil(try hooks(inJSONAt: hooksTarget)["Stop"], "the hooks landed in the linked file")
        let toml = try String(contentsOfFile: configTarget, encoding: .utf8)
        XCTAssertTrue(toml.contains("hooks = true"))
        XCTAssertTrue(toml.contains("model = \"o3\""))

        // A second install (Codex rewrites hooks.json every time) keeps it too.
        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: sandbox + "/primary", peers: []), .installed)
        XCTAssertTrue(isSymlink(root + "/hooks.json"))
    }

    func testUninstallThroughASymlinkedSettingsFileKeepsTheLink() throws {
        let root = try makeDir("claude-work")
        try fm.createDirectory(atPath: root + "/projects", withIntermediateDirectories: true)
        let settings: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "~/.codeisland/codeisland-hook.sh"]]]]],
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        let target = try linkToDotfile(root + "/settings.json", named: "claude-settings.json", contents: text)
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .claude, path: root)))

        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)

        XCTAssertTrue(isSymlink(root + "/settings.json"))
        let cleaned = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fm.contents(atPath: target))) as? [String: Any])
        XCTAssertNil(cleaned["hooks"], "our hooks came out of the linked file")
        XCTAssertEqual(cleaned["model"] as? String, "opus")
    }

    // MARK: - Primary root (the same write paths)

    /// The primary Codex entry, rooted at `$CODEX_HOME`: before the fix its
    /// hooks.json and config.toml symlinks were replaced by copies as well.
    func testPrimaryCodexRootKeepsItsSymlinkedFiles() throws {
        let home = try makeDir("codex")
        setenv("CODEX_HOME", home, 1)
        let hooksTarget = try linkToDotfile(home + "/hooks.json", named: "primary-hooks.json", contents: "{}\n")
        let configTarget = try linkToDotfile(home + "/config.toml", named: "primary-config.toml", contents: "[features]\nhooks = false\n")
        let primary = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })
        XCTAssertEqual(primary.fullPath, home + "/hooks.json")

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: primary, fm: fm))
        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: fm))
        XCTAssertTrue(isSymlink(home + "/hooks.json"))
        XCTAssertTrue(isSymlink(home + "/config.toml"))
        XCTAssertNotNil(try hooks(inJSONAt: hooksTarget)["Stop"])
        let toml = try String(contentsOfFile: configTarget, encoding: .utf8)
        XCTAssertTrue(toml.hasPrefix("[features]\nhooks = true"))
        XCTAssertFalse(toml.contains("hooks = false"))

        ConfigInstaller.uninstallHooks(cli: primary, fm: fm)
        XCTAssertTrue(isSymlink(home + "/hooks.json"))
        XCTAssertTrue(try hooks(inJSONAt: hooksTarget).isEmpty)
    }

    /// A regular (non-symlinked) primary file is still replaced in place —
    /// the only behaviour change is for symlinks.
    func testPrimaryRegularFileIsWrittenInPlaceAsBefore() throws {
        let home = try makeDir("codex-plain")
        setenv("CODEX_HOME", home, 1)
        let primary = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: primary, fm: fm))
        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: fm))
        XCTAssertFalse(isSymlink(home + "/hooks.json"))
        XCTAssertNotNil(try hooks(inJSONAt: home + "/hooks.json")["Stop"])
        XCTAssertTrue(try String(contentsOfFile: home + "/config.toml", encoding: .utf8).contains("hooks = true"))
    }

    func testAlwaysAllowRuleGoesIntoASymlinkedRulesFile() throws {
        let home = try makeDir("codex-rules")
        setenv("CODEX_HOME", home, 1)
        try fm.createDirectory(atPath: home + "/rules", withIntermediateDirectories: true)
        let target = try linkToDotfile(home + "/rules/codeisland.rules", named: "codeisland.rules", contents: "")
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "_source": "codex",
            "tool_name": "Bash",
            "tool_input": ["command": "npm run build"],
        ])))

        XCTAssertTrue(CodexPermissionRules().persistAlwaysAllowRule(for: event))

        XCTAssertTrue(isSymlink(home + "/rules/codeisland.rules"))
        XCTAssertTrue(try String(contentsOfFile: target, encoding: .utf8).contains(#"pattern = ["npm", "run", "build"]"#))
    }
}
