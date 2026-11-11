import Foundation
import Darwin
import CodeIslandCore

/// Resolve a terminal-owned Codex process against the current tmux server.
/// A daemon's inherited TMUX_PANE is not a per-session location.
enum CodexTmuxRouting {
    struct Pane: Equatable {
        let id: String
        let pid: pid_t
        var title: String = ""
        var cwd: String = ""
        var command: String = ""
        /// `#{session_id}` of the tmux session holding the pane.
        var session: String = ""
    }

    struct Client: Equatable {
        let tty: String
        /// `#{session_id}` the client is showing.
        let session: String
    }

    enum Resolution: Equatable {
        /// The pane holding the session's process, or the one live Codex pane
        /// showing the session's title in its directory.
        case located(Pane)
        /// The process is alive but outside every pane of this server, so the
        /// hook's pane is not where the session runs, and no single pane shows
        /// its title. Switching to the hook's pane would land on another session.
        case ambiguous
        /// Nothing to check against (no server answer, no live process): the
        /// hook's pane is the best evidence left, as for every other source.
        case unverified

        var pane: Pane? {
            if case .located(let pane) = self { return pane }
            return nil
        }
    }

    /// The title goes last: it is free text, so a tab in it must not shift the
    /// fields before it.
    static let paneFormat =
        "#{pane_id}\t#{pane_pid}\t#{session_id}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}"
    static let clientFormat = "#{client_tty}\t#{session_id}"

    /// The one place a session's tmux target is decided: for the jump
    /// (TerminalActivator) and for checking whether it landed or is in view
    /// (TerminalVisibilityDetector), so the two can't disagree. Only a Codex
    /// session in a tmux pane is second-guessed; any other session answers
    /// `.unverified`, keeping its hook's pane, without running anything.
    /// Blocking (runs tmux): call off the main thread.
    static func resolution(for session: SessionSnapshot, tmuxPath: String?) -> Resolution {
        guard session.source == "codex", let pane = session.tmuxPane, !pane.isEmpty,
              let tmuxPath else { return .unverified }
        return probe(session: session, tmuxPath: tmuxPath)
    }

    /// Read-only probe, also used by the integration tests. Never switches a pane.
    static func probe(session: SessionSnapshot, tmuxPath: String) -> Resolution {
        let env = session.tmuxEnv.map { ["TMUX": $0] }
        guard let data = ProcessRunner.run(path: tmuxPath, args: ["list-panes", "-a", "-F", paneFormat],
                                           env: env, timeout: 2),
              let output = String(data: data, encoding: .utf8) else { return .unverified }
        return resolve(session: session, panes: parsePanes(output), parentOf: { pid in
            processInfo(pid).map { pid_t($0.pbi_ppid) }
        }, startTime: { pid in
            processInfo(pid).map { Date(timeIntervalSince1970: TimeInterval($0.pbi_start_tvsec)) }
        })
    }

    static func parsePanes(_ output: String) -> [Pane] {
        output.split(separator: "\n").compactMap { line -> Pane? in
            let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let pid = pid_t(fields[1]) else { return nil }
            return Pane(id: String(fields[0]), pid: pid, title: String(fields[5]),
                        cwd: String(fields[4]), command: String(fields[3]), session: String(fields[2]))
        }
    }

    static func parseClients(_ output: String) -> [Client] {
        output.split(separator: "\n").compactMap { line -> Client? in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return Client(tty: String(fields[0]), session: String(fields[1]))
        }
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func resolve(
        session: SessionSnapshot,
        panes: [Pane],
        parentOf: (pid_t) -> pid_t?,
        startTime: (pid_t) -> Date?
    ) -> Resolution {
        // A gone or reused PID says nothing about where the session was.
        guard !panes.isEmpty, let pid = session.cliPid, pid > 1,
              let actualStart = startTime(pid) else { return .unverified }
        if let expectedStart = session.cliStartTime,
           abs(actualStart.timeIntervalSince(expectedStart)) >= 1 { return .unverified }

        var current = pid
        var visited = Set<pid_t>()
        while current > 1, visited.count < 64, visited.insert(current).inserted {
            let matches = panes.filter { $0.pid == current }
            if matches.count == 1 { return .located(matches[0]) }
            guard matches.isEmpty, let parent = parentOf(current) else { break }
            current = parent
        }

        // Shared app-server hooks carry the daemon's environment, not the TUI's.
        // Codex TUI publishes its current thread title in the pane title. This is
        // a constrained fallback, not a session-ID mapping: reject all ambiguity.
        guard let title = session.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, let cwd = session.cwd, !cwd.isEmpty else { return .ambiguous }
        let path = (cwd as NSString).standardizingPath
        let expected = "\(title) | \((path as NSString).lastPathComponent)"
        let matches = panes.filter {
            $0.command == "codex" && ($0.cwd as NSString).standardizingPath == path
                && normalizedTitle($0.title) == expected
        }
        return matches.count == 1 ? .located(matches[0]) : .ambiguous
    }

    /// The client to show `pane` in: one already showing its session (the
    /// hook's own client first), else the hook's client, else the only client.
    /// nil leaves the choice to tmux, as `switch-client` without `-c` always did.
    static func client(for pane: Pane, clients: [Client], preferred: String?) -> String? {
        let attachedPreferred = preferred.flatMap { tty in clients.contains { $0.tty == tty } ? tty : nil }
        let showing = pane.session.isEmpty ? [] : clients.filter { $0.session == pane.session }
        if let attachedPreferred, showing.contains(where: { $0.tty == attachedPreferred }) {
            return attachedPreferred
        }
        if let first = showing.first { return first.tty }
        if let attachedPreferred { return attachedPreferred }
        return clients.count == 1 ? clients[0].tty : nil
    }

    static func normalizedTitle(_ value: String) -> String {
        // TUI's working indicator is one braille spinner followed by a space.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) else { return trimmed }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
