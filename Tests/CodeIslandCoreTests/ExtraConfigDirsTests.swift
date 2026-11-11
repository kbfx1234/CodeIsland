import XCTest
@testable import CodeIslandCore

final class ExtraConfigDirsTests: XCTestCase {
    private let home = "/Users/tester"

    /// Fake filesystem: path → kind. Everything else is missing.
    private func probe(_ entries: [String: ConfigDirEntryKind]) -> (String) -> ConfigDirEntryKind {
        { entries[$0] ?? .missing }
    }

    /// Directory `root` holding `files` and `dirs`.
    private func layout(_ root: String, files: [String] = [], dirs: [String] = []) -> [String: ConfigDirEntryKind] {
        var entries: [String: ConfigDirEntryKind] = [root: .directory]
        for f in files { entries[root + "/" + f] = .file }
        for d in dirs { entries[root + "/" + d] = .directory }
        return entries
    }

    // Real top-level layouts (read-only listings of a developer machine,
    // trimmed): the default roots of each CLI.
    private var claudeRoot: [String: ConfigDirEntryKind] {
        layout("/r/claude", files: ["settings.json", "history.jsonl", "CLAUDE.md"],
               dirs: ["projects", "hooks", "plugins", "sessions", "shell-snapshots", "debug"])
    }
    private var codexRoot: [String: ConfigDirEntryKind] {
        layout("/r/codex", files: ["auth.json", "config.toml", ".codex-global-state.json", "AGENTS.md"],
               dirs: ["sessions", "archived_sessions", "cache"])
    }
    private var grokRoot: [String: ConfigDirEntryKind] {
        layout("/r/grok", files: ["config.toml", "active_sessions.json", ".metadata_version", "trusted_folders.toml", "version.json"],
               dirs: ["sessions", "hooks", "projects", "logs", "bin"])
    }

    // MARK: - Inspection

    func testEachCLIRecognisesItsOwnRoot() {
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/claude", cli: .claude, probe: probe(claudeRoot)), .ready)
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/codex", cli: .codex, probe: probe(codexRoot)), .ready)
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/grok", cli: .grok, probe: probe(grokRoot)), .ready)
    }

    /// Codex and Grok share `config.toml` and `sessions/`, and Grok even has a
    /// `projects/` like Claude — generic entries alone must not let one CLI's
    /// root pass as another's.
    func testAnotherCLIsRootIsNamedInsteadOfAccepted() {
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/codex", cli: .claude, probe: probe(codexRoot)), .belongsTo(.codex))
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/codex", cli: .grok, probe: probe(codexRoot)), .belongsTo(.codex))
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/grok", cli: .codex, probe: probe(grokRoot)), .belongsTo(.grok))
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/grok", cli: .claude, probe: probe(grokRoot)), .belongsTo(.grok))
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/claude", cli: .codex, probe: probe(claudeRoot)), .belongsTo(.claude))
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/r/claude", cli: .grok, probe: probe(claudeRoot)), .belongsTo(.claude))
    }

    /// A fresh root the CLI has only just started using may hold nothing but
    /// its session store — that still counts.
    func testFreshRootWithOnlyTheSessionStoreIsAccepted() {
        let claude = layout("/fresh", dirs: ["projects"])
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/fresh", cli: .claude, probe: probe(claude)), .ready)
        let codex = layout("/fresh", files: ["config.toml"], dirs: ["sessions"])
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/fresh", cli: .codex, probe: probe(codex)), .ready)
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/fresh", cli: .grok, probe: probe(codex)), .ready)
    }

    func testMissingFileAndUnrelatedDirectoriesSayWhy() {
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/nope", cli: .claude, probe: probe([:])), .missing)
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/f", cli: .claude, probe: probe(["/f": .file])), .notADirectory)
        let documents = layout("/Users/tester/Documents", files: ["notes.txt"], dirs: ["Work"])
        XCTAssertEqual(
            ExtraConfigDirs.inspect(path: "/Users/tester/Documents", cli: .claude, probe: probe(documents)),
            .unrecognized
        )
    }

    /// A stray *file* named like a marker directory is not evidence.
    func testMarkerKindMatters() {
        let entries = layout("/odd", files: ["projects", "sessions"])
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/odd", cli: .claude, probe: probe(entries)), .unrecognized)
        XCTAssertEqual(ExtraConfigDirs.inspect(path: "/odd", cli: .codex, probe: probe(entries)), .unrecognized)
    }

    // MARK: - Validation

    func testValidationNormalisesTheTypedPath() throws {
        let entries = layout(home + "/.claude-work", dirs: ["projects"])
        let result = ExtraConfigDirs.validateNew(
            rawPath: "  ~/.claude-work/ ",
            cli: .claude,
            primary: home + "/.claude",
            existing: [],
            homeDir: home,
            probe: probe(entries),
            identity: { $0 }
        )
        XCTAssertEqual(try result.get(), ExtraConfigDir(cli: .claude, path: home + "/.claude-work", enabled: true))
    }

    func testValidationRejectsBadInputWithAReason() {
        func validate(_ raw: String, existing: [ExtraConfigDir] = [], entries: [String: ConfigDirEntryKind] = [:])
            -> Result<ExtraConfigDir, ExtraConfigDirError> {
            ExtraConfigDirs.validateNew(
                rawPath: raw, cli: .codex, primary: home + "/.codex", existing: existing,
                homeDir: home, probe: probe(entries), identity: { $0 }
            )
        }
        XCTAssertEqual(validate(""), .failure(.invalidPath))
        XCTAssertEqual(validate("relative/dir"), .failure(.invalidPath))
        XCTAssertEqual(validate("/"), .failure(.invalidPath))
        XCTAssertEqual(validate("~/.codex/"), .failure(.isPrimary))
        XCTAssertEqual(
            validate("~/.codex-work", existing: [ExtraConfigDir(cli: .codex, path: home + "/.codex-work")]),
            .failure(.duplicate)
        )
        XCTAssertEqual(validate("~/.codex-typo"), .failure(.unusable(.missing)))
        XCTAssertEqual(
            validate("/r/grok", entries: grokRoot),
            .failure(.unusable(.belongsTo(.grok)))
        )
    }

    /// Without CLAUDE_CONFIG_DIR, `~/.claude.json` sits in the home folder, so
    /// it passes the marker check — and the folder picker opens on it.
    /// Registering it would put hooks in ~/settings.json and watch ~/projects.
    func testHomeFolderAndFoldersAroundThePrimaryAreRefused() throws {
        var entries = layout(home, files: [".claude.json"], dirs: ["projects", ".claude", ".config/claude"])
        entries.merge(layout(home + "/.claude-work", dirs: ["projects"])) { current, _ in current }
        entries["/Users"] = .directory
        XCTAssertEqual(ExtraConfigDirs.inspect(path: home, cli: .claude, probe: probe(entries)), .ready,
                       "the home folder does look like a Claude root")

        func validate(_ raw: String, primary: String? = nil, identity: @escaping (String) -> String = { $0 })
            -> Result<ExtraConfigDir, ExtraConfigDirError> {
            ExtraConfigDirs.validateNew(
                rawPath: raw, cli: .claude, primary: primary ?? home + "/.claude", existing: [],
                homeDir: home, probe: probe(entries), identity: identity
            )
        }
        XCTAssertEqual(validate("~"), .failure(.isHomeDirectory))
        XCTAssertEqual(validate("~/"), .failure(.isHomeDirectory))
        XCTAssertEqual(validate(home), .failure(.isHomeDirectory))
        XCTAssertEqual(
            validate("/Users/me-link", identity: { $0 == "/Users/me-link" ? self.home : $0 }),
            .failure(.isHomeDirectory),
            "a symlink to the home folder is the home folder"
        )
        XCTAssertEqual(validate("/Users"), .failure(.containsPrimary(home + "/.claude")))
        XCTAssertEqual(
            validate("~/.config", primary: home + "/.config/claude"),
            .failure(.containsPrimary(home + "/.config/claude"))
        )
        // A sibling that only shares the prefix is a directory of its own.
        XCTAssertEqual(try validate("~/.claude-work").get().path, home + "/.claude-work")
    }

    /// The same directory registered under another CLI is its own entry (and
    /// then fails inspection on its own merits), not a duplicate.
    func testDuplicateCheckIsPerCLI() {
        let entries = layout("/r/shared", files: ["config.toml"], dirs: ["sessions"])
        let result = ExtraConfigDirs.validateNew(
            rawPath: "/r/shared", cli: .grok, primary: home + "/.grok",
            existing: [ExtraConfigDir(cli: .codex, path: "/r/shared")],
            homeDir: home, probe: probe(entries), identity: { $0 }
        )
        XCTAssertEqual(try result.get().path, "/r/shared")
    }

    /// A symlink to the primary root is the primary root.
    func testSymlinkToPrimaryIsRejectedThroughIdentity() {
        let entries = layout(home + "/claude-link", dirs: ["projects"])
        let result = ExtraConfigDirs.validateNew(
            rawPath: "~/claude-link", cli: .claude, primary: home + "/.claude",
            existing: [], homeDir: home, probe: probe(entries),
            identity: { $0 == self.home + "/claude-link" ? self.home + "/.claude" : $0 }
        )
        XCTAssertEqual(result, .failure(.isPrimary))
    }

    // MARK: - Storage

    func testEncodeDecodeRoundTripAndGarbage() {
        let dirs = [
            ExtraConfigDir(cli: .claude, path: "/a", enabled: true),
            ExtraConfigDir(cli: .grok, path: "/b", enabled: false),
        ]
        XCTAssertEqual(ExtraConfigDirs.decode(ExtraConfigDirs.encode(dirs)), dirs)
        XCTAssertEqual(ExtraConfigDirs.decode(nil), [])
        XCTAssertEqual(ExtraConfigDirs.decode(""), [])
        XCTAssertEqual(ExtraConfigDirs.decode("not json"), [])
        XCTAssertEqual(ExtraConfigDirs.decode(#"[{"cli":"cursor","path":"/x","enabled":true}]"#), [])
    }

    func testLoadAndSaveGoThroughTheGivenDefaults() {
        let suite = "ExtraConfigDirsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ExtraConfigDirs.load(from: defaults), [])
        let dirs = [ExtraConfigDir(cli: .codex, path: "/c")]
        ExtraConfigDirs.save(dirs, to: defaults)
        XCTAssertEqual(ExtraConfigDirs.load(from: defaults), dirs)
        // An edit is picked up at once — the memo is keyed on the stored string.
        ExtraConfigDirs.save([], to: defaults)
        XCTAssertEqual(ExtraConfigDirs.load(from: defaults), [])
    }

    func testEnabledPathsFilterByCLIAndSwitch() {
        let dirs = [
            ExtraConfigDir(cli: .claude, path: "/c1"),
            ExtraConfigDir(cli: .claude, path: "/c2", enabled: false),
            ExtraConfigDir(cli: .codex, path: "/x1"),
        ]
        XCTAssertEqual(ExtraConfigDirs.enabledPaths(for: .claude, in: dirs), ["/c1"])
        XCTAssertEqual(ExtraConfigDirs.enabledPaths(for: .codex, in: dirs), ["/x1"])
        XCTAssertEqual(ExtraConfigDirs.enabledPaths(for: .grok, in: dirs), [])
    }

    // MARK: - Roots

    func testRootsKeepPrimaryFirstAndDropDuplicates() {
        XCTAssertEqual(
            ExtraConfigDirs.roots(primary: "/p", extras: ["/a", "/p", "/b", "/a"], identity: { $0 }),
            ["/p", "/a", "/b"]
        )
        // Two spellings of one directory (symlink) are scanned once.
        XCTAssertEqual(
            ExtraConfigDirs.roots(primary: "/p", extras: ["/link-to-p", "/b"], identity: { $0 == "/link-to-p" ? "/p" : $0 }),
            ["/p", "/b"]
        )
    }

    /// Files are compared, not roots: a Grok root whose `hooks/` is linked to
    /// the primary's, or two Claude accounts sharing one settings.json.
    func testSharedFileOwnerComparesTheFilesThemselves() {
        let identity: (String) -> String = { path in
            path.replacingOccurrences(of: "/x/hooks/", with: "/p/hooks/")
                .replacingOccurrences(of: "/b/settings.json", with: "/a/settings.json")
        }
        func owner(_ file: String, _ root: String, peers: [String] = []) -> String? {
            ExtraConfigDirs.sharedFileOwner(file, root: root, primary: "/p", peers: peers, identity: identity)
        }
        XCTAssertEqual(owner("hooks/codeisland.json", "/x"), "/p")
        XCTAssertNil(owner("config.toml", "/x"), "only the linked folder is shared")
        XCTAssertEqual(owner("settings.json", "/b", peers: ["/a"]), "/a")
        XCTAssertNil(owner("settings.json", "/a"))
        XCTAssertEqual(owner("settings.json", "/p"), "/p", "the primary itself")

        XCTAssertTrue(ExtraConfigDirs.isSameDirectory("/link", as: "/p", identity: { $0 == "/link" ? "/p" : $0 }))
        XCTAssertFalse(ExtraConfigDirs.isSameDirectory("/q", as: "/p", identity: { $0 }))
    }

    func testProcessRootFollowsTheProcessOwnEnvironment() {
        func root(_ env: [String: String]?, _ cli: ConfigDirCLI = .claude) -> String? {
            ExtraConfigDirs.processRoot(cli: cli, environment: env, homeDir: home, defaultRoot: "/default")
        }
        XCTAssertNil(root(nil), "unreadable environment: unknown, the caller tries every root")
        XCTAssertEqual(root([:]), "/default", "variable unset: the CLI's built-in default")
        XCTAssertEqual(root(["CLAUDE_CONFIG_DIR": "~/.claude-work"]), home + "/.claude-work")
        XCTAssertEqual(root(["CLAUDE_CONFIG_DIR": "/opt/acct/"]), "/opt/acct")
        XCTAssertEqual(root(["CLAUDE_CONFIG_DIR": "  "]), "/default")
        XCTAssertEqual(root(["CODEX_HOME": "/x"], .codex), "/x")
        XCTAssertEqual(root(["CODEX_HOME": "/x"], .grok), "/default", "each CLI reads only its own variable")
        XCTAssertEqual(root(["GROK_HOME": "~/g2"], .grok), home + "/g2")
    }

    func testOwningRootPicksTheDeepestContainingRoot() {
        let roots = ["/Users/t/.codex", "/Users/t/.codex/nested-account", "/Users/t/.codex-work"]
        XCTAssertEqual(
            ExtraConfigDirs.owningRoot(of: "/Users/t/.codex-work/sessions/2026/09/24/rollout-1.jsonl", among: roots),
            "/Users/t/.codex-work",
            "a sibling that merely shares a prefix is not a parent"
        )
        XCTAssertEqual(
            ExtraConfigDirs.owningRoot(of: "/Users/t/.codex/nested-account/sessions/r.jsonl", among: roots),
            "/Users/t/.codex/nested-account"
        )
        XCTAssertEqual(ExtraConfigDirs.owningRoot(of: "/Users/t/.codex/sessions/r.jsonl", among: roots), "/Users/t/.codex")
        XCTAssertNil(ExtraConfigDirs.owningRoot(of: "/elsewhere/r.jsonl", among: roots))
        XCTAssertNil(ExtraConfigDirs.owningRoot(of: nil, among: roots))
        XCTAssertNil(ExtraConfigDirs.owningRoot(of: "", among: roots))
    }

    // MARK: - Claude transcripts across roots

    func testTranscriptLookupSearchesEveryRootInOrder() {
        let existing: Set<String> = [
            "/work/projects/-p/s1.jsonl",
            "/main/projects/-p/s2.jsonl",
            "/work/projects/-p/s2.jsonl",
        ]
        let lookup = { (sid: String) in
            ClaudeConfigPaths.transcriptPath(
                projectDir: "-p", sessionId: sid, roots: ["/main", "/work"], fileExists: existing.contains)
        }
        XCTAssertEqual(lookup("s1"), "/work/projects/-p/s1.jsonl", "found in the extra root")
        XCTAssertEqual(lookup("s2"), "/main/projects/-p/s2.jsonl", "primary wins a tie")
        XCTAssertNil(lookup("s3"))
    }
}

/// Usage totals across several Claude config dirs.
final class ClaudeUsageMultiRootTests: XCTestCase {
    private var base: String!

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "usage-multiroot-" + UUID().uuidString
        for root in ["main", "work"] {
            try FileManager.default.createDirectory(
                atPath: "\(base!)/\(root)/projects/p", withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: base)
        super.tearDown()
    }

    private func line(id: String, at date: Date, output: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return """
        {"type":"assistant","timestamp":"\(f.string(from: date))","message":{"id":"\(id)","role":"assistant","usage":{"input_tokens":1,"output_tokens":\(output)}}}

        """  // trailing newline: the scanner only consumes complete lines
    }

    func testTotalsAddUpAcrossAccountsAndASymlinkedRootCountsOnce() throws {
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let hourAgo = now.addingTimeInterval(-3600)
        try line(id: "m-main", at: hourAgo, output: 10)
            .write(toFile: "\(base!)/main/projects/p/a.jsonl", atomically: true, encoding: .utf8)
        try line(id: "m-work", at: hourAgo, output: 32)
            .write(toFile: "\(base!)/work/projects/p/b.jsonl", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: "\(base!)/work-link", withDestinationPath: "\(base!)/work")

        var cache = ClaudeUsageScanner.FileCache()
        let snap = ClaudeUsageScanner.scan(
            claudeHomes: ["\(base!)/main", "\(base!)/work", "\(base!)/work-link"],
            now: now,
            cache: &cache
        )
        XCTAssertEqual(snap.last5h.outputTokens, 42)
        XCTAssertEqual(snap.last5h.messageCount, 2)

        // The single-home entry point still scans exactly that home.
        XCTAssertEqual(ClaudeUsageScanner.scan(claudeHome: "\(base!)/main", now: now).last5h.outputTokens, 10)
    }
}
