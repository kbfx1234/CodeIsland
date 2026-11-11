import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Install / detect / uninstall of hooks in extra config roots. Everything
/// runs inside a temporary directory: the real ~/.claude, ~/.codex, ~/.grok
/// and ~/.codeisland are never touched, and nothing here goes through
/// `installClaudeHooks` (it asks the installed `claude` for its version).
final class ExtraConfigDirInstallerTests: XCTestCase {
    private var sandbox: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        sandbox = fm.temporaryDirectory.appendingPathComponent("extra-config-dirs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: sandbox)
    }

    private func makeRoot(_ name: String, files: [String] = [], dirs: [String] = []) throws -> String {
        let root = sandbox.appendingPathComponent(name).path
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        for dir in dirs { try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true) }
        for file in files { XCTAssertTrue(fm.createFile(atPath: root + "/" + file, contents: Data("{}".utf8))) }
        return root
    }

    private func json(atPath path: String) throws -> [String: Any] {
        let data = try XCTUnwrap(fm.contents(atPath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Materialising the CLIConfig

    func testExtraRootReusesTheBuiltInEntryReRootedAtTheDirectory() throws {
        for (cli, file) in [(ConfigDirCLI.claude, "settings.json"), (.codex, "hooks.json"), (.grok, "hooks/codeisland.json")] {
            let config = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: cli, path: "/acct/\(cli)")))
            let builtIn = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == cli.source })
            XCTAssertEqual(config.source, cli.source, "events report as the ordinary \(cli) source")
            XCTAssertEqual(config.fullPath, "/acct/\(cli)/\(file)")
            XCTAssertEqual(config.extraConfigDir, "/acct/\(cli)")
            XCTAssertEqual(config.events.map(\.0), builtIn.events.map(\.0))
            XCTAssertEqual(config.format, builtIn.format)
            XCTAssertNil(builtIn.extraConfigDir, "the built-in entry is not marked")
        }
    }

    func testDisabledRootsAreLeftOutUnlessAsked() {
        let dirs = [
            ExtraConfigDir(cli: .claude, path: "/on"),
            ExtraConfigDir(cli: .codex, path: "/off", enabled: false),
        ]
        XCTAssertEqual(ConfigInstaller.extraConfigDirCLIs(in: dirs).map(\.extraConfigDir), ["/on"])
        XCTAssertEqual(
            ConfigInstaller.extraConfigDirCLIs(in: dirs, includeDisabled: true).map(\.extraConfigDir),
            ["/on", "/off"]
        )
    }

    // MARK: - Codex

    func testCodexRootGetsHooksAndItsOwnFeatureFlag() throws {
        let root = try makeRoot("codex-work", files: ["auth.json"], dirs: ["sessions"])
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .codex, path: root)))

        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: sandbox.appendingPathComponent("primary").path, peers: []), .installed)

        let hooks = try XCTUnwrap(try json(atPath: root + "/hooks.json")["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let command = try XCTUnwrap((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(command.hasSuffix("--source codex"))
        // Codex started with CODEX_HOME=<root> reads *this* config.toml.
        let toml = try String(contentsOfFile: root + "/config.toml", encoding: .utf8)
        XCTAssertTrue(toml.contains("hooks = true"))

        let status = try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: ExtraConfigDir(cli: .codex, path: root)))
        XCTAssertEqual(status.inspection, .ready)
        XCTAssertTrue(status.hooksInstalled)
        XCTAssertEqual(status.fullConfigPath, root + "/hooks.json")
    }

    func testUninstallFromAnExtraRootKeepsTheUsersOwnHooks() throws {
        let root = try makeRoot("codex-mixed", files: ["auth.json"])
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .codex, path: root)))
        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: sandbox.appendingPathComponent("primary").path, peers: []), .installed)

        var root_ = try json(atPath: root + "/hooks.json")
        var hooks = try XCTUnwrap(root_["hooks"] as? [String: Any])
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]
        root_["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root_).write(to: URL(fileURLWithPath: root + "/hooks.json"))

        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)

        let cleaned = try XCTUnwrap(try json(atPath: root + "/hooks.json")["hooks"] as? [String: Any])
        XCTAssertEqual(Array(cleaned.keys), ["Stop"])
        let remaining = try XCTUnwrap((cleaned["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(remaining.first?["command"] as? String, "/usr/bin/true")
        XCTAssertFalse(try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: ExtraConfigDir(cli: .codex, path: root))).hooksInstalled)
    }

    // MARK: - Grok

    func testGrokRootGetsItsHooksFile() throws {
        let root = try makeRoot("grok-2", files: ["config.toml", "active_sessions.json"], dirs: ["sessions"])
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .grok, path: root)))

        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: sandbox.appendingPathComponent("primary").path, peers: []), .installed)
        let hooks = try XCTUnwrap(try json(atPath: root + "/hooks/codeisland.json")["hooks"] as? [String: Any])
        XCTAssertFalse(hooks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: ExtraConfigDir(cli: .grok, path: root))).hooksInstalled)
    }

    // MARK: - Roots that cannot take hooks

    /// A registered root that vanished (unmounted volume, deleted account) is
    /// reported, never recreated.
    func testMissingRootIsSkippedAndNotRecreated() throws {
        let root = sandbox.appendingPathComponent("gone").path
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .codex, path: root)))

        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm), .skipped(.missing))
        XCTAssertFalse(fm.fileExists(atPath: root))

        let status = try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: ExtraConfigDir(cli: .codex, path: root)))
        XCTAssertEqual(status.inspection, .missing)
        XCTAssertFalse(status.hooksInstalled)
    }

    func testAnotherCLIsRootIsSkippedWithoutWritingIntoIt() throws {
        let root = try makeRoot("really-codex", files: ["auth.json", "config.toml"], dirs: ["sessions"])
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .grok, path: root)))

        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm), .skipped(.belongsTo(.codex)))
        XCTAssertFalse(fm.fileExists(atPath: root + "/hooks"))
    }

    // MARK: - Claude (detection and removal only)

    func testClaudeRootHooksAreDetectedAndRemoved() throws {
        let root = try makeRoot("claude-work", dirs: ["projects"])
        let dir = ExtraConfigDir(cli: .claude, path: root)
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: dir))

        // What installClaudeHooks writes: the shared hook script on every event,
        // next to a hook of the user's own.
        var hooks: [String: Any] = [:]
        for (event, timeout, _) in cli.events {
            hooks[event] = [["matcher": "", "hooks": [["type": "command", "command": "~/.codeisland/codeisland-hook.sh", "timeout": timeout]]]]
        }
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [["matcher": "", "hooks": [["type": "command", "command": "say done"]]]]
        let settings: [String: Any] = ["model": "opus", "hooks": hooks]
        try JSONSerialization.data(withJSONObject: settings).write(to: URL(fileURLWithPath: root + "/settings.json"))

        XCTAssertTrue(try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: dir)).hooksInstalled)

        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)

        let cleaned = try json(atPath: root + "/settings.json")
        XCTAssertEqual(cleaned["model"] as? String, "opus", "unrelated settings survive")
        let cleanedHooks = try XCTUnwrap(cleaned["hooks"] as? [String: Any])
        XCTAssertEqual(Array(cleanedHooks.keys), ["Stop"])
        XCTAssertFalse(try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: dir)).hooksInstalled)
    }

    // MARK: - Codex "Always allow" account

    /// The root was registered through a symlink; Codex reports the real
    /// transcript path. The rule must go to that account, not to the primary.
    func testAlwaysAllowTargetsTheAccountRegisteredThroughASymlink() throws {
        let work = try makeRoot("codex-work", files: ["auth.json"], dirs: ["sessions/2026/09/24"])
        let alias = sandbox.appendingPathComponent("codex-alias").path
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: work)
        let primary = try makeRoot("codex", files: ["auth.json"])
        let transcript = work + "/sessions/2026/09/24/rollout-1.jsonl"
        XCTAssertTrue(fm.createFile(atPath: transcript, contents: Data()))
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "_source": "codex",
            "transcript_path": transcript,
        ])))

        XCTAssertEqual(CodexPermissionRules.codexHome(for: event, roots: [primary, alias], primary: primary), alias)
        let unrelated = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": "s2", "_source": "codex",
        ])))
        XCTAssertEqual(CodexPermissionRules.codexHome(for: unrelated, roots: [primary, alias], primary: primary), primary)
    }

    // MARK: - Settings wiring

    func testSettingsKeyMatchesTheCoreKey() {
        XCTAssertEqual(SettingsKey.extraConfigDirs, ExtraConfigDirs.preferenceKey)
    }

    func testEveryReasonHasWording() {
        let l10n = L10n.shared
        let saved = l10n.language
        l10n.language = "en"
        defer { l10n.language = saved }

        let reasons: [ConfigDirInspection] = [.missing, .notADirectory, .unrecognized, .belongsTo(.codex)]
        for reason in reasons {
            let text = try? XCTUnwrap(ExtraConfigDirText.inspection(reason, cli: .claude, l10n: l10n))
            XCTAssertNotNil(text)
            XCTAssertFalse(text?.hasPrefix("extra_dir_") ?? true, "missing translation for \(reason)")
        }
        XCTAssertEqual(
            ExtraConfigDirText.inspection(.belongsTo(.codex), cli: .claude, l10n: l10n),
            "Looks like a Codex config directory, not a Claude Code one"
        )
        XCTAssertTrue(
            ExtraConfigDirText.inspection(.unrecognized, cli: .codex, l10n: l10n)?.contains("CODEX_HOME") == true,
            "the fix names the variable to set"
        )
        for error: ExtraConfigDirError in [
            .invalidPath, .isPrimary, .duplicate, .unusable(.missing),
            .isHomeDirectory, .containsPrimary("/Users/t/.grok"),
        ] {
            XCTAssertFalse(ExtraConfigDirText.error(error, cli: .grok, l10n: l10n).hasPrefix("extra_dir_"))
        }
    }

    /// The two refusals added for the home folder name what to pick instead,
    /// in every language.
    func testHomeAndParentFolderRefusalsSayWhatToPick() {
        let l10n = L10n.shared
        let saved = l10n.language
        defer { l10n.language = saved }
        for language in ["en", "de", "zh", "zhHant", "ja", "ko", "tr"] {
            l10n.language = language
            let home = ExtraConfigDirText.error(.isHomeDirectory, cli: .claude, l10n: l10n)
            XCTAssertTrue(home.contains("CLAUDE_CONFIG_DIR"), "\(language): \(home)")
            let parent = ExtraConfigDirText.error(.containsPrimary("/opt/acct/.codex"), cli: .codex, l10n: l10n)
            XCTAssertTrue(parent.contains("Codex") && parent.contains("/opt/acct/.codex"), "\(language): \(parent)")
        }
    }
}
