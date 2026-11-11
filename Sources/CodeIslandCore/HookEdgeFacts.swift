import Foundation

/// What an edge that cannot run HookIntake sends instead of interpreting its
/// hook: the facts it observed, in its payload's `_edge` object, next to the
/// agent's stdin object (docs/hook-edge-protocol.md). HookServer runs
/// HookIntake on them as codeisland-bridge does on its own side, so the
/// remote hook gets the bridge's interpretation instead of a copy of it.
///
/// A payload without `_edge` is its edge's own interpretation — the bridge's,
/// a plugin's, a remote hook installed before this existed — and is taken as
/// it is.
///
/// Every edge that sends facts runs on another machine: the bridge, the one
/// edge on this Mac, reads its own and drops an `_edge` piped into it. So no
/// fact is ever taken for this Mac's — no pid is tracked, no home or file of
/// this Mac consulted — whatever `host` says, or if it says nothing. Nor is
/// `host` the edge's word: by the time facts are read, the island has put
/// there the host whose socket they arrived on (``HookOrigin``).
public enum HookEdgeFacts {
    /// The payload key the facts travel under.
    public static let key = "_edge"

    /// The version of the facts this island reads. Fields are added without
    /// changing it; it changes only if a field changes meaning. Facts naming
    /// another version are read for the fields this one knows.
    public static let version = 1

    /// What an `_edge` payload delivers.
    public enum Delivery {
        /// Nothing to forward: the facts rule it out (CODEISLAND_SKIP, a hook
        /// Grok imported) or it names no session. The edge gets no answer.
        case dropped
        case interpreted(HookIntake)
    }

    private static let keyBytes = Data(#""_edge""#.utf8)

    /// Cheap probe on the raw bytes: a payload that cannot carry facts is
    /// never parsed for them.
    public static func mayCarryFacts(_ data: Data) -> Bool {
        data.range(of: keyBytes) != nil
    }

    /// What `payload` delivers, or nil when it carries no `_edge` facts.
    public static func delivery(in payload: [String: Any]) -> Delivery? {
        guard let edge = payload[key] as? [String: Any] else { return nil }
        let facts = facts(from: edge)
        guard HookIntake.admits(sourceTag: facts.sourceTag, environment: facts.environment) else {
            return .dropped
        }
        // A blank cwd is no cwd: the edge's own (or Grok's workspace) stands
        // in for it, as the remote hook put its own in place of one before it
        // sent facts. An event without a cwd is dropped on a host with a cwd
        // allow-list (#240).
        var stdin = payload
        if let cwd = stdin["cwd"] as? String, cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stdin.removeValue(forKey: "cwd")
        }
        guard var intake = HookIntake(stdin: stdin, facts: facts) else { return .dropped }
        intake.addTerminalContext()
        return .interpreted(intake)
    }

    /// HookIntake's facts from an `_edge` object: those of another machine.
    public static func facts(from edge: [String: Any]) -> HookIntake.Facts {
        let source = string(edge["source"])
        // Claude Code's hook is the one other agents run too — Cursor imports it
        // (#377), omo fires it — so on this Mac it carries no `--source`, and the
        // payload or the process tree names the agent. An edge's `claude` is that
        // same hook: read as no tag, with Claude what is left when nothing else
        // names the agent.
        let isClaudesOwnHook = SessionSnapshot.normalizedSupportedSource(source) == "claude"
        let environment = (edge["env"] as? [String: Any] ?? [:])
            .compactMapValues { $0 as? String }
            .filter { HookIntake.environmentKeys.contains($0.key) }
        let workingDirectory = string(edge["cwd"])
        let tty = string(edge["tty"])
        let digest = string(edge["stdin_sha256"])
        let tmuxClientTTY = string(edge["tmux_client_tty"])

        // Another machine, even when `host` is missing or malformed: none of
        // its processes, files or home are this Mac's, so no `ppid` is read
        // and nothing is looked up here (the defaults: no home, no file).
        let host = edge["host"] as? [String: Any]
        return HookIntake.Facts(
            sourceTag: isClaudesOwnHook ? nil : source,
            eventTag: string(edge["event"]),
            defaultSource: isClaudesOwnHook ? "claude" : nil,
            environment: environment,
            workingDirectory: { workingDirectory },
            tty: { tty },
            remoteHost: HookIntake.EdgeHost(
                id: host?["id"] as? String ?? "",
                name: host?["name"] as? String ?? ""
            ),
            stdinDigest: { digest },
            edgeWaits: edge["waits"] as? Bool,
            tmuxClientTTY: { _ in tmuxClientTTY }
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }
}
