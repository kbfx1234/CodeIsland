import Foundation
import CodeIslandCore

/// Kiro V3 writes a lease for the process that owns each session and a small
/// session record alongside its transcript. The lease ties a turn to a live PID.
enum KiroDiscovery {
    private struct Lease: Decodable {
        let pid: pid_t
        let clientName: String?
        let acquiredAt: String
    }

    private struct Record: Decodable {
        let id: String
        let status: String
        let rootPaths: [String]
        let modelId: String?
        let lastModifiedAt: String
    }

    static func activeSessions(
        sessionId: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro"),
        kiroProcess: (pid_t) -> ProcessIdentity? = liveKiroProcess
    ) -> [DiscoveredSession] {
        let fm = FileManager.default
        let leaseDir = home.appendingPathComponent("session-leases")
        let leases: [URL]
        if let sessionId {
            guard (sessionId as NSString).lastPathComponent == sessionId else { return [] }
            leases = [leaseDir.appendingPathComponent(sessionId + ".lease")]
        } else {
            leases = (try? fm.contentsOfDirectory(at: leaseDir, includingPropertiesForKeys: nil)) ?? []
        }
        let sessionsDir = home.appendingPathComponent("sessions")
        let workspaces = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()

        return leases.compactMap { url in
            guard url.pathExtension == "lease" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let lease = try? decoder.decode(Lease.self, from: data),
                  lease.clientName == "kiro-cli" || lease.clientName == "t3-code",
                  let process = kiroProcess(lease.pid),
                  let startedAt = process.startTime,
                  let acquiredAt = SessionDiscovery.parseISO8601Timestamp(lease.acquiredAt),
                  acquiredAt >= startedAt else { return nil }

            return activeSession(id, pid: process.pid, acquiredAt: acquiredAt, workspaces: workspaces, decoder: decoder)
        }
    }

    private static func activeSession(
        _ id: String, pid: pid_t, acquiredAt: Date, workspaces: [URL], decoder: JSONDecoder
    ) -> DiscoveredSession? {
        for workspace in workspaces {
            let url = workspace.appendingPathComponent(id).appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.id == id, record.status == "in_progress",
                  let cwd = record.rootPaths.first, cwd.hasPrefix("/"),
                  let modifiedAt = SessionDiscovery.parseISO8601Timestamp(record.lastModifiedAt),
                  modifiedAt >= acquiredAt else { continue }
            return DiscoveredSession(
                sessionId: id, cwd: cwd, tty: nil, model: record.modelId, pid: pid,
                modifiedAt: modifiedAt, recentMessages: [], source: "kiro", status: .processing
            )
        }
        return nil
    }

    private static func liveKiroProcess(_ pid: pid_t) -> ProcessIdentity? {
        guard let process = ProcessTable.liveProcessIdentity(for: pid),
              let executable = ProcessTable.executablePath(for: pid),
              CLIProcessResolver.sourceMatchesExecutablePath(executable, source: "kiro") else { return nil }
        return process
    }
}
