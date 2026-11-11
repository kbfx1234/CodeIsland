import Foundation

// MARK: - CLIs with relocatable config roots

/// A CLI whose whole config root moves with one environment variable, so a
/// user with several accounts runs it against several directories:
/// `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`.
///
/// Each CLI still has exactly one *primary* root — the one the rest of
/// CodeIsland always used (`ClaudeConfigPaths.configDir()`,
/// `ConfigInstaller.codexHome()` / `grokHome()`). Extra roots registered in
/// Settings → Hooks are layered on top: hooks are installed in each of them,
/// and session discovery, transcript lookups and Claude usage read all of them.
public enum ConfigDirCLI: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok

    /// `CLIConfig.source` of the built-in entry these directories extend. Hooks
    /// installed in an extra root report under the same source, so its sessions
    /// are ordinary Claude / Codex / Grok cards.
    public var source: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok CLI"
        }
    }

    /// The variable the CLI reads to pick its root.
    public var environmentKey: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .grok: return "GROK_HOME"
        }
    }

    /// Where the CLI's per-session transcripts live, relative to its root.
    public var sessionStoreSubdirectory: String {
        switch self {
        case .claude: return "projects"
        case .codex, .grok: return "sessions"
        }
    }

    /// Files and directories that prove a directory is this CLI's root.
    ///
    /// `distinctive` entries are written only by this CLI (among the three), so
    /// one of them settles the question. `generic` ones are shared with a
    /// sibling (`config.toml`, `sessions/`, `history.jsonl`…) and only count
    /// when no *other* CLI's distinctive entry is present — that is what tells
    /// `~/.codex` apart from `~/.grok` although both hold `config.toml` and
    /// `sessions/`.
    var markers: (distinctive: [ConfigDirMarker], generic: [ConfigDirMarker]) {
        switch self {
        case .claude:
            return (
                [.file("settings.json"), .file(".claude.json"), .file(".credentials.json"),
                 .directory("statsig"), .directory("todos"), .directory("shell-snapshots")],
                [.directory("projects"), .file("history.jsonl"), .directory("plugins")]
            )
        case .codex:
            return (
                [.file("auth.json"), .file(".codex-global-state.json"), .file("state_5.sqlite"),
                 .file("hooks.json"), .directory("archived_sessions")],
                [.file("config.toml"), .directory("sessions"), .file("history.jsonl"), .directory("log")]
            )
        case .grok:
            return (
                [.file("active_sessions.json"), .file(".metadata_version"), .file("trusted_folders.toml"),
                 .file("worktrees.db")],
                [.file("config.toml"), .directory("sessions"), .directory("hooks"), .directory("logs")]
            )
        }
    }
}

struct ConfigDirMarker: Equatable {
    let name: String
    let isDirectory: Bool

    static func file(_ name: String) -> ConfigDirMarker { ConfigDirMarker(name: name, isDirectory: false) }
    static func directory(_ name: String) -> ConfigDirMarker { ConfigDirMarker(name: name, isDirectory: true) }
}

/// What a path is on disk — the only filesystem fact the pure checks need.
public enum ConfigDirEntryKind: Equatable, Sendable {
    case missing
    case file
    case directory

    /// The real probe. `fileExists(atPath:isDirectory:)` follows symlinks, so a
    /// symlinked config dir (a common multi-account setup) counts as a directory.
    public static func probe(_ path: String) -> ConfigDirEntryKind {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .missing }
        return isDir.boolValue ? .directory : .file
    }
}

// MARK: - Model

/// One extra config root registered in Settings → Hooks.
public struct ExtraConfigDir: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let cli: ConfigDirCLI
    /// Absolute, normalized: `~` expanded, no trailing slash, Unicode NFC.
    public let path: String
    /// Monitoring switch for this one directory. Off removes its hooks and
    /// drops it from discovery without forgetting the registration.
    public var enabled: Bool

    public var id: String { cli.rawValue + ":" + path }

    public init(cli: ConfigDirCLI, path: String, enabled: Bool = true) {
        self.cli = cli
        self.path = path
        self.enabled = enabled
    }
}

/// Why a directory can or cannot take hooks. Shown verbatim (localized) in
/// Settings next to the directory — never a bare "skipped".
public enum ConfigDirInspection: Equatable, Sendable {
    case ready
    /// Nothing at that path (typo, unmounted volume, deleted account).
    case missing
    /// The path is a file.
    case notADirectory
    /// A directory, but none of the CLI's own files are in it.
    case unrecognized
    /// Clearly another CLI's root (e.g. `~/.codex` registered as Claude Code).
    case belongsTo(ConfigDirCLI)
}

public enum ExtraConfigDirError: Error, Equatable, Sendable {
    /// Empty, relative, or `/`.
    case invalidPath
    /// Same directory as the CLI's primary root.
    case isPrimary
    /// The home folder itself. Without `CLAUDE_CONFIG_DIR`, Claude Code keeps
    /// `~/.claude.json` there, so it would pass as a Claude root — and then get
    /// hooks in `~/settings.json`, a recursive watch on `~/projects` (often
    /// the user's code folder) and a usage scan of it. The folder picker
    /// opens on it, so one stray click is enough.
    case isHomeDirectory
    /// A folder that holds the primary root (e.g. `~/.config` for
    /// `~/.config/claude`), carried so the message can name it.
    case containsPrimary(String)
    /// Already registered for this CLI.
    case duplicate
    /// Exists-and-looks-right check failed; carries the reason.
    case unusable(ConfigDirInspection)
}

// MARK: - Registry

public enum ExtraConfigDirs {
    /// UserDefaults key (a JSON string). Mirrored by `SettingsKey.extraConfigDirs`.
    public static let preferenceKey = "extra_config_dirs_v1"

    // MARK: Storage

    public static func decode(_ raw: String?) -> [ExtraConfigDir] {
        guard let raw, let data = raw.data(using: .utf8), !data.isEmpty,
              let dirs = try? JSONDecoder().decode([ExtraConfigDir].self, from: data) else { return [] }
        return dirs
    }

    public static func encode(_ dirs: [ExtraConfigDir]) -> String {
        guard let data = try? JSONEncoder().encode(dirs),
              let raw = String(data: data, encoding: .utf8) else { return "" }
        return raw
    }

    private static let cacheLock = NSLock()
    private static var cachedRaw: String?
    private static var cachedDirs: [ExtraConfigDir] = []

    /// Registered directories. Read on every discovery scan and transcript
    /// lookup, so the decode is memoized on the raw stored string — an edit in
    /// Settings changes the string and is picked up immediately.
    public static func load(from defaults: UserDefaults = .standard) -> [ExtraConfigDir] {
        let raw = defaults.string(forKey: preferenceKey) ?? ""
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if raw == cachedRaw { return cachedDirs }
        let dirs = decode(raw)
        cachedRaw = raw
        cachedDirs = dirs
        return dirs
    }

    public static func save(_ dirs: [ExtraConfigDir], to defaults: UserDefaults = .standard) {
        defaults.set(encode(dirs), forKey: preferenceKey)
    }

    /// Enabled extra roots for one CLI, in registration order.
    public static func enabledPaths(for cli: ConfigDirCLI, in dirs: [ExtraConfigDir]) -> [String] {
        dirs.filter { $0.cli == cli && $0.enabled }.map(\.path)
    }

    public static func enabledPaths(for cli: ConfigDirCLI) -> [String] {
        enabledPaths(for: cli, in: load())
    }

    // MARK: Roots

    /// Identity used to decide that two spellings are the same directory or
    /// file: `realpath` (symlinks resolved, on-disk case) plus NFC, so
    /// `~/.claude-work`, a symlink to it and `~/.Claude-Work` typed by hand are
    /// one root — scanned, counted and hooked once. See `ConfigPathIdentity`.
    public static func identity(of path: String) -> String {
        ConfigPathIdentity.identity(of: path)
    }

    private static let rootsCacheLock = NSLock()
    private static var rootsCache: [String: [String]] = [:]

    /// Primary root first, then the extras, without duplicates.
    ///
    /// Read on every hook event (title and transcript lookups) and discovery
    /// scan, so the result is memoized on the spellings passed in, like
    /// `load()` is on the stored string: a Settings edit changes the key and
    /// is picked up at once, while the steady state costs no `realpath`. A
    /// symlink created on disk afterwards is only seen once the inputs change
    /// or `invalidateRootsCache()` runs (Reinstall does) — at worst one root
    /// is read twice; hook writes never go through this cache.
    public static func roots(primary: String, extras: [String]) -> [String] {
        let key = ([primary] + extras).joined(separator: "\u{0}")
        rootsCacheLock.lock()
        if let cached = rootsCache[key] {
            rootsCacheLock.unlock()
            return cached
        }
        rootsCacheLock.unlock()

        let result = roots(primary: primary, extras: extras, identity: identity(of:))
        rootsCacheLock.lock()
        // Keys only change with the configuration; the cap just bounds a
        // session that keeps editing it.
        if rootsCache.count >= 32 { rootsCache.removeAll() }
        rootsCache[key] = result
        rootsCacheLock.unlock()
        return result
    }

    /// Unmemoized `roots(primary:extras:)` with an injected identity.
    public static func roots(
        primary: String,
        extras: [String],
        identity: (String) -> String
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in [primary] + extras where seen.insert(identity(path)).inserted {
            result.append(path)
        }
        return result
    }

    /// Forget memoized `roots` — after a Reinstall, or anything else that may
    /// have moved directories around on disk.
    public static func invalidateRootsCache() {
        rootsCacheLock.lock()
        rootsCache.removeAll()
        rootsCacheLock.unlock()
    }

    // MARK: Shared directories and files

    /// Whether `path` is the directory `other` under another spelling
    /// (symlink, letter case). Checked at the time of use, not only when a
    /// directory is registered: the primary moves when `claude_config_dir`
    /// changes or CodeIsland starts with another `CODEX_HOME` / `GROK_HOME`,
    /// and a symlink can be created after registration.
    public static func isSameDirectory(
        _ path: String,
        as other: String,
        identity: (String) -> String = ExtraConfigDirs.identity(of:)
    ) -> Bool {
        identity(path) == identity(other)
    }

    /// The root whose `relativePath` (`settings.json`, `hooks.json`,
    /// `config.toml`, `hooks/codeisland.json`…) is the very same file on disk
    /// as `root`'s — the primary root first, then `peers` in order — or nil
    /// when `root`'s file is its own.
    ///
    /// Two accounts often share one `settings.json` through a symlink, and a
    /// Grok root's `hooks/` folder may be linked to another root's. Whoever
    /// owns that file manages CodeIsland's hooks in it; writing or removing
    /// them through the other root would undo exactly what the owner needs —
    /// removing a paused extra root must never strip the primary's hooks.
    /// Files are compared, not roots, so a shared file inside two distinct
    /// roots is caught too.
    public static func sharedFileOwner(
        _ relativePath: String,
        root: String,
        primary: String,
        peers: [String],
        identity: (String) -> String = ExtraConfigDirs.identity(of:)
    ) -> String? {
        let mine = identity(root + "/" + relativePath)
        return ([primary] + peers).first { identity($0 + "/" + relativePath) == mine }
    }

    /// The root a running CLI process reads, from its own environment.
    ///
    /// - `environment == nil`: the process environment could not be read (or
    ///   only in part), so the root is unknown — see `ConfigRootSnapshot`.
    /// - variable set to an absolute path: that directory, whether or not it
    ///   is registered — the process writes there no matter what Settings says.
    /// - variable set to anything else (a relative path, `/`): unknown too.
    ///   The CLI resolves it against its own working directory; it is not
    ///   "unset", and treating it so would pin the process to the default.
    /// - variable unset or blank: the CLI's built-in default (`defaultRoot`).
    ///
    /// Matching per process is what keeps two sessions of the same CLI in the
    /// same project, but on different accounts, from being cross-wired.
    public static func processRoot(
        cli: ConfigDirCLI,
        environment: [String: String]?,
        homeDir: String,
        defaultRoot: String
    ) -> String? {
        guard let environment else { return nil }
        guard let raw = environment[cli.environmentKey],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultRoot
        }
        return ClaudeConfigPaths.normalized(raw, homeDir: homeDir)
    }

    /// The root among `roots` that contains `path` (a transcript the CLI
    /// reported, say) — how a hook event is traced back to the account it came
    /// from. The deepest match wins, so a root nested in another is not
    /// swallowed by its parent.
    ///
    /// Both sides are compared by `identity`: the CLI reports the path it
    /// built from its own variable, while the root may be registered as a
    /// symlink or with different letter case. A spelling mismatch must not
    /// fall back to the primary account — that is how "Always allow" would
    /// land in another account's rules.
    public static func owningRoot(
        of path: String?,
        among roots: [String],
        identity: (String) -> String = ExtraConfigDirs.identity(of:)
    ) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let candidate = identity(path)
        return roots
            .map { (root: $0, identity: identity($0)) }
            .filter { candidate == $0.identity || candidate.hasPrefix($0.identity + "/") }
            .max { $0.identity.count < $1.identity.count }?
            .root
    }

    // MARK: Validation

    /// Does `path` look like `cli`'s root? Pure: all filesystem access goes
    /// through `probe`.
    public static func inspect(
        path: String,
        cli: ConfigDirCLI,
        probe: (String) -> ConfigDirEntryKind = ConfigDirEntryKind.probe
    ) -> ConfigDirInspection {
        switch probe(path) {
        case .missing: return .missing
        case .file: return .notADirectory
        case .directory: break
        }
        func present(_ marker: ConfigDirMarker) -> Bool {
            let kind = probe(path + "/" + marker.name)
            return marker.isDirectory ? kind == .directory : kind == .file
        }
        if cli.markers.distinctive.contains(where: present) { return .ready }
        if let rival = ConfigDirCLI.allCases.first(where: { other in
            other != cli && other.markers.distinctive.contains(where: present)
        }) {
            return .belongsTo(rival)
        }
        if cli.markers.generic.contains(where: present) { return .ready }
        return .unrecognized
    }

    /// Validate a path typed (or picked) in Settings before it is registered.
    public static func validateNew(
        rawPath: String,
        cli: ConfigDirCLI,
        primary: String,
        existing: [ExtraConfigDir],
        homeDir: String,
        probe: (String) -> ConfigDirEntryKind = ConfigDirEntryKind.probe,
        identity: (String) -> String = ExtraConfigDirs.identity(of:)
    ) -> Result<ExtraConfigDir, ExtraConfigDirError> {
        guard let path = ClaudeConfigPaths.normalized(rawPath, homeDir: homeDir) else {
            return .failure(.invalidPath)
        }
        let id = identity(path)
        if id == identity(homeDir) { return .failure(.isHomeDirectory) }
        let primaryID = identity(primary)
        if id == primaryID { return .failure(.isPrimary) }
        if primaryID.hasPrefix(id + "/") { return .failure(.containsPrimary(primary)) }
        if existing.contains(where: { $0.cli == cli && identity($0.path) == id }) {
            return .failure(.duplicate)
        }
        let inspection = inspect(path: path, cli: cli, probe: probe)
        guard inspection == .ready else { return .failure(.unusable(inspection)) }
        return .success(ExtraConfigDir(cli: cli, path: path))
    }
}
