import Foundation
import CodeIslandCore

enum RexRouting {
    static let bundleID = "com.superlogical.rex"

    static func matches(_ session: SessionSnapshot) -> Bool {
        session.rexBlockId?.isEmpty == false || session.rexSessionId?.isEmpty == false
            || session.termBundleId?.lowercased() == bundleID || session.termApp?.lowercased() == "rex"
    }

    static func run(_ path: String, _ args: [String]) -> Data? {
        let env = ["REX_SESSION": "", "REX_WINDOW": "", "REX_BLOCK": "", "REX_CLIENT": "", "REX_SERVER": ""]
        return ProcessRunner.run(path: path, args: ["--autostart=false", "--timeout", "1s"] + args, env: env, timeout: 2)
    }

    struct TmuxTarget {
        let blockID: String
        let paneID: String
        let client: CodexTmuxRouting.Client
    }

    static func jump(_ session: SessionSnapshot, tmuxPath: String?, appPID: pid_t?, command: ([String]) -> Data?) {
        if session.tmuxPane?.isEmpty == false {
            guard let tmuxPath, let target = tmuxTarget(for: session, tmuxPath: tmuxPath, rex: command) else { return }
            if target.client.activePane != target.paneID {
                guard ProcessRunner.run(
                    path: tmuxPath, args: ["switch-client", "-E", "-c", target.client.tty, "-t", target.paneID],
                    env: ["TMUX": session.tmuxEnv ?? ""], timeout: 2
                ) != nil else { return }
            }
            focus(blockID: target.blockID, savedSessionID: nil, appPID: appPID, command: command)
        } else if let blockID = session.rexBlockId, !blockID.isEmpty {
            focus(blockID: blockID, savedSessionID: session.rexSessionId, appPID: appPID, command: command)
        }
    }

    static func tmuxTarget(
        for session: SessionSnapshot, tmuxPath: String, rex: ([String]) -> Data?
    ) -> TmuxTarget? {
        guard let savedPane = session.tmuxPane, !savedPane.isEmpty else { return nil }
        let pane: String
        switch CodexTmuxRouting.resolution(for: session, tmuxPath: tmuxPath) {
        case .located(let resolved): pane = resolved.id
        case .unverified: pane = savedPane
        case .ambiguous: return nil
        }
        let env = ["TMUX": session.tmuxEnv ?? ""]
        let commands: ([String]) -> String? = { args in
            ProcessRunner.run(path: tmuxPath, args: args, env: env, timeout: 2)
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        guard let destination = commands(["display-message", "-p", "-t", pane, "#{session_id}\t#{pane_id}"])?
                .trimmingCharacters(in: .newlines).split(separator: "\t"),
              destination.count == 2,
              let listing = commands(["list-clients", "-F", CodexTmuxRouting.clientFormat]) else { return nil }
        return tmuxTarget(
            pane: String(destination[1]), sessionID: String(destination[0]), preferredTTY: session.tmuxClientTty,
            clients: CodexTmuxRouting.parseClients(listing),
            environment: AppState.rexTerminalEnvironment(for:), rex: rex
        )
    }

    static func isBlockFocused(_ blockID: String, command: ([String]) -> Data?) -> Bool {
        guard let session = json(command(["session", "inspect", "--json", "--", blockID])),
              let activeWindow = session["active_window_id"] as? String,
              let windows = session["windows"] as? [[String: Any]] else { return false }
        return windows.contains {
            $0["window_id"] as? String == activeWindow && $0["focused_block_id"] as? String == blockID
        }
    }

    static func tmuxTarget(
        pane: String, sessionID: String, preferredTTY: String?,
        clients: [CodexTmuxRouting.Client], environment: (pid_t) -> [String: String]?, rex: ([String]) -> Data?
    ) -> TmuxTarget? {
        func priority(_ client: CodexTmuxRouting.Client) -> Int {
            (client.session == sessionID ? 0 : 2) + (client.tty == preferredTTY ? 0 : 1)
        }

        // Read each attached client's environment. The pane's own REX_BLOCK
        // can be inherited from whichever terminal started the tmux server.
        for client in clients.sorted(by: { priority($0) < priority($1) }) {
            guard let pid = client.pid, pid > 1,
                  let blockID = environment(pid)?["REX_BLOCK"], !blockID.isEmpty,
                  let process = json(rex(["block", "call", "-b", blockID, "process"])) else { continue }
            let foreground = process["foreground"] as? [String: Any]
            let child = process["child"] as? [String: Any]
            if foreground?["pid"] as? Int == Int(pid) || child?["pid"] as? Int == Int(pid) {
                return TmuxTarget(blockID: blockID, paneID: pane, client: client)
            }
        }
        return nil
    }

    /// The block can move between sessions. Use its current location to select
    /// the right session in the local GUI client before updating server focus.
    static func focus(
        blockID: String, savedSessionID: String?, appPID: pid_t?, command: ([String]) -> Data?
    ) {
        let location = json(command(["block", "inspect", "--json", "--", blockID]))
        let sessionID = location?["session_id"] as? String
        let windowID = (location?["block"] as? [String: Any])?["window_id"] as? String
        if let sessionID, let appPID,
           let clients = json(command(["client", "ls", "--json"]))?["clients"] as? [[String: Any]],
           let clientID = localAppClient(in: clients, pid: appPID) {
            var select = ["-C", clientID, "do", "session.select", "session_id=\(sessionID)"]
            if let windowID { select.append("window_id=\(windowID)") }
            _ = command(select)
        }
        let scope = (sessionID ?? savedSessionID).flatMap { $0.isEmpty ? nil : ["-s", $0] } ?? []
        _ = command(["block", "focus"] + scope + ["--", blockID])
    }

    private static func localAppClient(in clients: [[String: Any]], pid: pid_t) -> String? {
        clients.first { client in
            let info = client["info"] as? [String: Any]
            let principal = client["principal"] as? [String: Any]
            return client["connection_state"] as? String == "connected" && info?["kind"] as? String == "app"
                && principal?["transport"] as? String == "unix" && principal?["pid"] as? Int == Int(pid)
        }?["client_id"] as? String
    }

    private static func json(_ data: Data?) -> [String: Any]? {
        data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}
