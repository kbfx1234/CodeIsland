import Foundation
import Darwin
import CodeIslandCore

/// Exit watches on the local CLI processes behind session cards: one
/// `DispatchSourceProcess` per watched session, and the liveness sweep that
/// catches what those sources miss. AppState decides which process a session
/// belongs to and what an exit means for its card; this type holds the
/// watches.
@MainActor
final class SessionProcessMonitor {
    struct Watch {
        let source: DispatchSourceProcess
        let process: ProcessIdentity
        /// The watched process's ppid captured when the watch was attached.
        /// Processes that already had ppid <= 1 at attach time are
        /// launchd-managed daemons (e.g. a Hermes gateway with KeepAlive=true),
        /// NOT orphans of a closed terminal — they must never be terminated by
        /// orphan cleanup (#243).
        let attachParentPid: pid_t?
    }

    /// Cancelled from `deinit`, which may run off the main actor (AppState is
    /// released there by async XCTest ARC). Only mutated on the main actor.
    nonisolated(unsafe) private var watches: [String: Watch] = [:]

    deinit {
        for (_, watch) in watches {
            watch.source.cancel()
        }
    }

    /// The process `sessionId` is watched on, if any.
    func watchedProcess(for sessionId: String) -> ProcessIdentity? {
        watches[sessionId]?.process
    }

    func isWatching(_ sessionId: String) -> Bool {
        watches[sessionId] != nil
    }

    /// Watch `process` for exit on behalf of `sessionId`; `onExit` runs on
    /// the main actor when it exits. False when the session already has a
    /// watch (it is left as is).
    func watch(
        sessionId: String,
        process: ProcessIdentity,
        onExit: @escaping @MainActor () -> Void
    ) -> Bool {
        guard watches[sessionId] == nil else { return false }
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                onExit()
            }
        }
        source.resume()
        watches[sessionId] = Watch(
            source: source,
            process: process,
            attachParentPid: ProcessTable.parentPid(of: process.pid)
        )
        return true
    }

    func stop(_ sessionId: String) {
        watches[sessionId]?.source.cancel()
        watches.removeValue(forKey: sessionId)
    }

    func stopAll() {
        for key in Array(watches.keys) { stop(key) }
    }

    /// Verify the watched processes (DispatchSource can silently miss exits):
    /// those no longer the same live process, and live ones reparented to
    /// launchd since their watch was attached (terminal closed, process
    /// survived) — candidates for orphan cleanup.
    func sweep() -> (exited: [(sessionId: String, process: ProcessIdentity)],
                     reparented: [(sessionId: String, pid: pid_t)]) {
        var exited: [(sessionId: String, process: ProcessIdentity)] = []
        var reparented: [(sessionId: String, pid: pid_t)] = []
        for (sessionId, watch) in watches {
            let process = watch.process
            // Check if the watched process is still the same live process.
            if !ProcessTable.isLiveProcess(process) {
                exited.append((sessionId, process))
                continue
            }
            // Orphaned: ppid <= 1 now, but only if the process had a real
            // parent when we attached. A process whose ppid was already <= 1
            // at attach time is a launchd-managed daemon, not a terminal
            // orphan — killing it puts KeepAlive daemons into a
            // SIGTERM/restart loop (#243).
            if Self.isReparentedOrphan(
                currentParentPid: ProcessTable.parentPid(of: process.pid),
                attachParentPid: watch.attachParentPid
            ) {
                reparented.append((sessionId, process.pid))
            }
        }
        return (exited, reparented)
    }

    /// A process counts as a terminal orphan only when it USED to have a real parent
    /// (attachParentPid > 1) and has since been reparented to launchd/init (ppid <= 1).
    /// Daemons started by launchd have ppid <= 1 from the beginning and are never
    /// orphans, no matter how long they run (#243). Unknown attach ppid stays safe: no kill.
    nonisolated static func isReparentedOrphan(currentParentPid: pid_t?, attachParentPid: pid_t?) -> Bool {
        guard let currentParentPid, currentParentPid <= 1 else { return false }
        guard let attachParentPid, attachParentPid > 1 else { return false }
        return true
    }
}
