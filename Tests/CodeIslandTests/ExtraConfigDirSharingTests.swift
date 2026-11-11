import XCTest
@testable import CodeIsland
import CodeIslandCore

/// An extra config dir whose hooks file turns out to be the primary's (or
/// another enabled root's) must never have CodeIsland's hooks written into or
/// taken out of it through the extra entry. Sandboxed: a temporary directory
/// stands in for every root, the primary is injected, registrations live in a
/// throw-away UserDefaults suite, and nothing goes through
/// `installClaudeHooks` (it asks the installed `claude` for its version) or
/// the ~/.codeisland script/bridge install.
final class ExtraConfigDirSharingTests: XCTestCase {
    private var sandbox: String!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fm = FileManager.default
    private let ourClaudeCommand = "~/.codeisland/codeisland-hook.sh"

    override func setUpWithError() throws {
        sandbox = fm.temporaryDirectory.appendingPathComponent("extra-config-sharing-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
        suiteName = "ExtraConfigDirSharingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(atPath: sandbox)
    }

    // MARK: - Helpers

    private func makeRoot(_ name: String, files: [String] = [], dirs: [String] = []) throws -> String {
        let root = sandbox + "/" + name
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        for dir in dirs { try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true) }
        for file in files { XCTAssertTrue(fm.createFile(atPath: root + "/" + file, contents: Data("{}".utf8))) }
        return root
    }

    private func link(_ path: String, to destination: String) throws {
        try fm.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    /// What `installClaudeHooks` writes, without asking `claude` its version.
    private func writeClaudeSettingsWithOurHooks(at path: String) throws {
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .claude, path: "/unused")))
        var hooks: [String: Any] = [:]
        for (event, timeout, _) in cli.events {
            hooks[event] = [["matcher": "", "hooks": [["type": "command", "command": ourClaudeCommand, "timeout": timeout]]]]
        }
        try JSONSerialization.data(withJSONObject: ["model": "opus", "hooks": hooks]).write(to: URL(fileURLWithPath: path))
    }

    /// Hooks installed into `root` as an extra Codex/Grok root would get them.
    private func installExternal(_ cli: ConfigDirCLI, into root: String) throws {
        let config = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: cli, path: root)))
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: config, fm: fm))
    }

    private func hasOurHooks(at path: String) -> Bool {
        guard let data = fm.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("codeisland") == true
            } == true
        }
    }

    private func register(_ dirs: [ExtraConfigDir]) {
        ExtraConfigDirs.save(dirs, to: defaults)
    }

    // MARK: - The directory became the primary

    /// (a) `~/.claude-work` registered, then `claude_config_dir` pointed at it:
    /// removing the entry must not uninstall the (now primary) hooks.
    func testRemovingADirThatBecameThePrimaryKeepsThePrimaryHooks() throws {
        let work = try makeRoot("claude-work", dirs: ["projects"])
        try writeClaudeSettingsWithOurHooks(at: work + "/settings.json")
        let dir = ExtraConfigDir(cli: .claude, path: work)
        register([dir])

        XCTAssertTrue(ConfigInstaller.extraConfigDirCLIs(in: [dir], primaryRoot: { _ in work }).isEmpty,
                      "never installed or repaired through the extra entry")
        let status = try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: dir, in: [dir], primaryRoot: work))
        XCTAssertTrue(status.sameAsPrimary)

        XCTAssertEqual(ConfigInstaller.removeExtraConfigDir(id: dir.id, defaults: defaults, primaryRoot: { _ in work }), dir)
        XCTAssertTrue(hasOurHooks(at: work + "/settings.json"))
        XCTAssertEqual(ExtraConfigDirs.load(from: defaults), [])
    }

    /// (b) CodeIsland started with `CODEX_HOME` = the registered root: pausing
    /// the entry must leave that (primary) hooks.json alone.
    func testPausingADirThatIsThePrimaryCodexHomeKeepsItsHooks() throws {
        let work = try makeRoot("codex-work", files: ["auth.json"])
        try installExternal(.codex, into: work)
        let dir = ExtraConfigDir(cli: .codex, path: work)
        register([dir])

        XCTAssertNil(ConfigInstaller.setExtraConfigDirEnabled(id: dir.id, enabled: false, defaults: defaults, primaryRoot: { _ in work }))
        XCTAssertTrue(hasOurHooks(at: work + "/hooks.json"))
        XCTAssertEqual(ExtraConfigDirs.load(from: defaults).first?.enabled, false)
    }

    /// (c) The registered directory was replaced by a symlink to the primary
    /// after it was registered (registration-time checks cannot see that).
    func testASymlinkToThePrimaryCreatedAfterRegistrationIsRecognised() throws {
        let primary = try makeRoot("claude", dirs: ["projects"])
        try writeClaudeSettingsWithOurHooks(at: primary + "/settings.json")
        let alias = sandbox + "/claude-work"
        try link(alias, to: primary)
        let dir = ExtraConfigDir(cli: .claude, path: alias)
        register([dir])

        ConfigInstaller.removeExtraConfigDir(id: dir.id, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertTrue(hasOurHooks(at: primary + "/settings.json"))
    }

    // MARK: - Shared files inside distinct roots

    /// Two Claude accounts sharing one settings.json through a symlink.
    func testPausingAnAccountThatSharesThePrimarySettingsFileKeepsItsHooks() throws {
        let primary = try makeRoot("claude", dirs: ["projects"])
        try writeClaudeSettingsWithOurHooks(at: primary + "/settings.json")
        let work = try makeRoot("claude-work", dirs: ["projects"])
        try link(work + "/settings.json", to: primary + "/settings.json")
        let dir = ExtraConfigDir(cli: .claude, path: work)
        register([dir])

        let status = try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: dir, in: [dir], primaryRoot: primary))
        XCTAssertFalse(status.sameAsPrimary, "its own account (projects, credentials) — only the file is shared")
        XCTAssertEqual(status.sharedHooksWith, primary)

        ConfigInstaller.setExtraConfigDirEnabled(id: dir.id, enabled: false, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertTrue(hasOurHooks(at: primary + "/settings.json"))
        ConfigInstaller.removeExtraConfigDir(id: dir.id, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertTrue(hasOurHooks(at: primary + "/settings.json"))
    }

    /// (d) A Grok root whose `hooks/` folder is linked to the primary's: the
    /// roots differ, the managed file is the same.
    func testGrokRootWithALinkedHooksFolderLeavesThePrimaryFileAlone() throws {
        let primary = try makeRoot("grok", files: ["active_sessions.json"], dirs: ["sessions", "hooks"])
        try installExternal(.grok, into: primary)
        let second = try makeRoot("grok-2", files: ["active_sessions.json"], dirs: ["sessions"])
        try link(second + "/hooks", to: primary + "/hooks")
        let dir = ExtraConfigDir(cli: .grok, path: second)
        register([dir])
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: dir))

        XCTAssertEqual(
            ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: primary, peers: []),
            .shared(with: primary)
        )
        XCTAssertEqual(
            try XCTUnwrap(ConfigInstaller.extraConfigDirStatus(for: dir, in: [dir], primaryRoot: primary)).sharedHooksWith,
            primary
        )

        ConfigInstaller.setExtraConfigDirEnabled(id: dir.id, enabled: false, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertTrue(hasOurHooks(at: primary + "/hooks/codeisland.json"))
        ConfigInstaller.removeExtraConfigDir(id: dir.id, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertTrue(hasOurHooks(at: primary + "/hooks/codeisland.json"))
    }

    /// Two extra Codex roots sharing one hooks.json: the earlier one manages
    /// it, and pausing the later one leaves the earlier one's hooks in place.
    /// The later root still gets `hooks = true` in its own config.toml.
    func testTwoExtraRootsSharingAHooksFile() throws {
        let first = try makeRoot("codex-a", files: ["auth.json"])
        let second = try makeRoot("codex-b", files: ["auth.json"])
        try link(second + "/hooks.json", to: first + "/hooks.json")
        let primary = try makeRoot("codex", files: ["auth.json"])
        let dirs = [ExtraConfigDir(cli: .codex, path: first), ExtraConfigDir(cli: .codex, path: second)]
        register(dirs)
        let firstCLI = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: dirs[0]))
        let secondCLI = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: dirs[1]))

        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: firstCLI, fm: fm, primaryRoot: primary, peers: []), .installed)
        XCTAssertEqual(
            ConfigInstaller.installHooks(inExtraDir: secondCLI, fm: fm, primaryRoot: primary, peers: [first]),
            .shared(with: first)
        )
        XCTAssertTrue(try String(contentsOfFile: second + "/config.toml", encoding: .utf8).contains("hooks = true"))

        ConfigInstaller.setExtraConfigDirEnabled(id: dirs[1].id, enabled: false, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertTrue(hasOurHooks(at: first + "/hooks.json"), "the first root still uses them")

        // With the other root gone too, its own removal takes the hooks out.
        ConfigInstaller.removeExtraConfigDir(id: dirs[1].id, defaults: defaults, primaryRoot: { _ in primary })
        ConfigInstaller.removeExtraConfigDir(id: dirs[0].id, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertFalse(hasOurHooks(at: first + "/hooks.json"))
    }

    /// Without any sharing, removal still takes the hooks out as before.
    func testAnIndependentRootIsStillCleanedUp() throws {
        let work = try makeRoot("codex-work", files: ["auth.json"])
        try installExternal(.codex, into: work)
        let primary = try makeRoot("codex", files: ["auth.json"])
        let dir = ExtraConfigDir(cli: .codex, path: work)
        register([dir])

        ConfigInstaller.removeExtraConfigDir(id: dir.id, defaults: defaults, primaryRoot: { _ in primary })
        XCTAssertFalse(hasOurHooks(at: work + "/hooks.json"))
    }

    // MARK: - Wording

    func testSharedStatesHaveWording() throws {
        let l10n = L10n.shared
        let saved = l10n.language
        defer { l10n.language = saved }
        let dir = ExtraConfigDir(cli: .claude, path: "/Users/t/.claude-work")
        let base = ExtraConfigDirStatus(
            dir: dir, inspection: .ready, hooksInstalled: true, sourceEnabled: true,
            displayConfigPath: "~/.claude-work/settings.json", fullConfigPath: "/Users/t/.claude-work/settings.json"
        )
        var same = base
        same.sameAsPrimary = true
        var shared = base
        shared.sharedHooksWith = "/Users/t/.claude"

        for language in ["en", "de", "zh", "zhHant", "ja", "ko", "tr"] {
            l10n.language = language
            let sameNote = try XCTUnwrap(ExtraConfigDirText.statusNote(same, l10n: l10n))
            XCTAssertFalse(sameNote.hasPrefix("extra_dir_"), "\(language)")
            XCTAssertTrue(sameNote.contains("Claude Code"), "\(language)")
            XCTAssertNil(ExtraConfigDirText.statusProblem(same, l10n: l10n))
            let sharedNote = try XCTUnwrap(ExtraConfigDirText.statusNote(shared, l10n: l10n))
            XCTAssertTrue(sharedNote.contains("settings.json") && sharedNote.contains("/Users/t/.claude"), "\(language): \(sharedNote)")
            let added = ExtraConfigDirText.added(dir, outcome: .shared(with: "/Users/t/.claude"), l10n: l10n)
            XCTAssertFalse(added.hasPrefix("extra_config_dirs_"), "\(language)")
            XCTAssertTrue(added.contains("settings.json"), "\(language): \(added)")
        }
    }
}
