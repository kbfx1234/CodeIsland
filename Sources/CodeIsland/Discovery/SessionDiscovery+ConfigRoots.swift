import Foundation
import Darwin
import CodeIslandCore

/// One CLI's config roots for one discovery scan, and how a running process
/// of that CLI maps onto them (`ConfigRootSnapshot` has the policy).
struct ConfigRootScan {
    let cli: ConfigDirCLI
    /// Root the CLI uses when its variable is unset.
    let defaultRoot: String
    let snapshot: ConfigRootSnapshot

    var fallbackRoots: [String] { snapshot.fallbackRoots }

    /// Where discovery looks for `pid`: its own root, skipped when that root
    /// is a paused extra directory, or unknown when its environment could not
    /// be read in full.
    func lookup(pid: pid_t) -> ProcessConfigRoot {
        snapshot.lookup(ExtraConfigDirs.processRoot(
            cli: cli,
            environment: SessionDiscovery.configRootEnvironment(for: pid),
            homeDir: FileManager.default.homeDirectoryForCurrentUser.path,
            defaultRoot: defaultRoot
        ))
    }
}

/// Session discovery across several config roots of the same CLI — the primary
/// one plus the extra Claude Code / Codex / Grok roots registered in
/// Settings → Hooks (`ExtraConfigDirs`).
///
/// Discovery maps a *running process* to its transcript. With one root there
/// was nothing to decide; with several, each process is matched against the
/// root it actually uses, read from its own `CLAUDE_CONFIG_DIR` / `CODEX_HOME`
/// / `GROK_HOME` (`ConfigRootDiscovery.run`). Only when that environment
/// cannot be read does a process fall back to the known roots, one at a time.
extension SessionDiscovery {
    /// The config-root variables of a running process, or nil when its
    /// environment cannot be read in full (then the root is unknown, not
    /// "default").
    static func configRootEnvironment(for pid: pid_t) -> [String: String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let keys = Set(ConfigDirCLI.allCases.map(\.environmentKey))
        return ProcArgsParser.completeEnvironment(Array(buffer.prefix(size)), keys: keys)
    }

    /// `cli`'s roots for one discovery scan: identities resolved once here,
    /// not per process.
    static func configRootScan(for cli: ConfigDirCLI) -> ConfigRootScan {
        let defaultRoot: String
        switch cli {
        case .claude: defaultRoot = ClaudeConfigPaths.defaultDirForUnsetEnvironment()
        case .codex: defaultRoot = defaultCodexRoot
        case .grok: defaultRoot = defaultGrokRoot
        }
        return ConfigRootScan(
            cli: cli,
            defaultRoot: defaultRoot,
            snapshot: ConfigRootSnapshot(
                cli: cli,
                primary: ConfigInstaller.primaryConfigRoot(for: cli),
                defaultRoot: defaultRoot,
                registered: ExtraConfigDirs.load()
            )
        )
    }

    /// Root a Codex process without `$CODEX_HOME` uses.
    static var defaultCodexRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.codex"
    }

    /// Root a Grok process without `$GROK_HOME` uses.
    static var defaultGrokRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.grok"
    }

    /// Session stores of the extra roots, for the discovery watcher. The
    /// primary stores are listed by `discoveryWatchRoots` itself, which also
    /// drops a store that is one of those under another spelling.
    static func extraConfigDirWatchRoots() -> [(source: String, path: String)] {
        ExtraConfigDirs.load()
            .filter(\.enabled)
            .map { ($0.cli.source, "\($0.path)/\($0.cli.sessionStoreSubdirectory)") }
    }

    /// Codex roots whose state DB, rollouts and thread index may hold a given
    /// thread. `~/.codex` stays first — it is where these lookups always looked
    /// and where Codex Desktop keeps its state — followed by CodeIsland's own
    /// `$CODEX_HOME` (when launched from a shell) and the extra roots.
    static func codexStateRoots() -> [String] {
        ExtraConfigDirs.roots(primary: defaultCodexRoot, extras: ConfigInstaller.codexHomes())
    }
}
