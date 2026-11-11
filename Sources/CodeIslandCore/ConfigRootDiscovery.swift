import Foundation

// MARK: - Where to look for one process

/// Where session discovery looks for the transcripts of one running
/// Claude Code / Codex / Grok process.
public enum ProcessConfigRoot: Equatable, Sendable {
    /// The root its own `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `GROK_HOME` names
    /// (or the default when unset), registered in Settings or not.
    case root(String)
    /// That root is an extra directory the user registered and then paused:
    /// the process is left out of discovery, as the switch promises.
    case paused
    /// Its environment could not be read in full: try the fallback roots.
    case unknown
}

/// One CLI's roots, resolved once per discovery scan rather than per process.
///
/// Policy for a process whose root is **not registered**: it is still
/// discovered, in its own root. The user may simply not have registered a
/// directory they do use, and before extra directories existed such a
/// process was found by its cwd all the same — dropping it would be a
/// regression. Only an explicit pause removes a root from discovery.
public struct ConfigRootSnapshot {
    /// Roots an unknown-environment process is tried against, in order: the
    /// primary, the CLI's default for an unset variable (what most processes
    /// use — CodeIsland may itself run with another `CODEX_HOME`), then the
    /// enabled extra roots. Paused roots are never among them.
    public let fallbackRoots: [String]
    private let pausedIdentities: Set<String>
    private let identity: (String) -> String

    public init(
        cli: ConfigDirCLI,
        primary: String,
        defaultRoot: String,
        registered: [ExtraConfigDir],
        identity: @escaping (String) -> String = ExtraConfigDirs.identity(of:)
    ) {
        let mine = registered.filter { $0.cli == cli }
        let enabledExtras = mine.filter(\.enabled).map(\.path)
        // A paused directory that is also the primary, or also registered and
        // enabled under another spelling, stays in.
        let active = Set(([primary] + enabledExtras).map(identity))
        let paused = Set(mine.filter { !$0.enabled }.map { identity($0.path) }).subtracting(active)
        self.pausedIdentities = paused
        self.identity = identity
        self.fallbackRoots = ExtraConfigDirs.roots(
            primary: primary,
            extras: [defaultRoot] + enabledExtras,
            identity: identity
        ).filter { !paused.contains(identity($0)) }
    }

    /// Where to look for a process whose own root is `root` (nil: unknown).
    public func lookup(_ root: String?) -> ProcessConfigRoot {
        guard let root else { return .unknown }
        // Nothing paused (the usual case): no path to resolve per process.
        guard !pausedIdentities.isEmpty else { return .root(root) }
        return pausedIdentities.contains(identity(root)) ? .paused : .root(root)
    }
}

// MARK: - Discovery across roots

public enum ConfigRootDiscovery {
    /// Session discovery for processes spread over several config roots.
    ///
    /// Processes whose root is known are grouped by root *identity* (a
    /// symlinked or differently-cased spelling is the same group) and each
    /// group is matched against its own root only, so two accounts in one
    /// project never trade sessions. Paused roots are skipped.
    ///
    /// A process whose environment is unknown then goes into exactly one
    /// root: `fallbackRoots` are tried in order, and the first that yields a
    /// session for it keeps it. It never competes in a known group, so it
    /// cannot take a session that a process with a known root claimed, and it
    /// cannot surface once per root as several cards.
    ///
    /// - Parameters:
    ///   - discover: sessions of `processes` under `root`. `claimed` holds
    ///     the ids already taken; results with those ids are dropped anyway,
    ///     but a matcher can leave them out up front to pick another.
    ///   - sessionId: key for de-duplication across roots.
    ///   - belongsTo: whether a session was found for a given process — a
    ///     resolved unknown process is not tried against later roots.
    public static func run<Process, Session>(
        processes: [Process],
        lookup: (Process) -> ProcessConfigRoot,
        fallbackRoots: [String],
        identity: (String) -> String = ExtraConfigDirs.identity(of:),
        discover: (_ root: String, _ processes: [Process], _ claimed: Set<String>) -> [Session],
        sessionId: (Session) -> String,
        belongsTo: (Session, Process) -> Bool
    ) -> [Session] {
        var identities: [String: String] = [:]
        func key(_ root: String) -> String {
            if let known = identities[root] { return known }
            let resolved = identity(root)
            identities[root] = resolved
            return resolved
        }

        var groups: [(root: String, processes: [Process])] = []
        var groupIndex: [String: Int] = [:]
        var unknown: [Process] = []
        for process in processes {
            switch lookup(process) {
            case .paused:
                continue
            case .unknown:
                unknown.append(process)
            case .root(let root):
                let rootKey = key(root)
                if let index = groupIndex[rootKey] {
                    groups[index].processes.append(process)
                } else {
                    groupIndex[rootKey] = groups.count
                    groups.append((root, [process]))
                }
            }
        }

        var results: [Session] = []
        var claimed = Set<String>()
        func accept(_ sessions: [Session]) -> [Session] {
            let accepted = sessions.filter { claimed.insert(sessionId($0)).inserted }
            results.append(contentsOf: accepted)
            return accepted
        }

        for group in groups {
            _ = accept(discover(group.root, group.processes, claimed))
        }

        var pending = unknown
        var tried = Set<String>()
        for root in fallbackRoots where !pending.isEmpty && tried.insert(key(root)).inserted {
            let accepted = accept(discover(root, pending, claimed))
            pending.removeAll { process in accepted.contains { belongsTo($0, process) } }
        }
        return results
    }
}
