import Foundation
import Darwin

/// Codex hooks can run in a shared daemon whose CMUX environment belongs to
/// the terminal that originally launched it. Resolve the live TUI instead.
public enum CmuxTerminalResolver {
    public struct Target: Equatable {
        public let pid: Int32
        public let surfaceId: String
        public let workspaceId: String
    }

    struct Candidate {
        let pid: Int32
        let cwd: String
        let hasTTY: Bool
        let surfaceId: String
        let workspaceId: String
    }

    static func resolve(
        cwd: String, candidates: [Candidate], preferredSurfaceId: String? = nil
    ) -> Target? {
        let matches = candidates.filter {
            $0.hasTTY && $0.cwd == cwd && !$0.surfaceId.isEmpty && !$0.workspaceId.isEmpty
        }
        let preferred = matches.filter { $0.surfaceId == preferredSurfaceId }
        let resolved = preferred.count == 1 ? preferred : matches
        guard resolved.count == 1, let process = resolved.first else { return nil }
        return Target(pid: process.pid, surfaceId: process.surfaceId, workspaceId: process.workspaceId)
    }

    public static func codexTarget(cwd: String?, preferredSurfaceId: String?) -> Target? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 32)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let candidates = pids.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.size)).compactMap { pid -> Candidate? in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  (String(cString: path) as NSString).lastPathComponent == "codex" else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.e_tdev != 0 else { return nil }
            var vnode = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
            let processCwd = withUnsafePointer(to: vnode.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard processCwd == cwd, let env = cmuxEnvironment(pid: pid) else { return nil }
            return Candidate(pid: pid, cwd: processCwd, hasTTY: true,
                             surfaceId: env["CMUX_SURFACE_ID"] ?? "",
                             workspaceId: env["CMUX_WORKSPACE_ID"] ?? "")
        }
        return resolve(cwd: cwd, candidates: candidates, preferredSurfaceId: preferredSurfaceId)
    }

    private static func cmuxEnvironment(pid: pid_t) -> [String: String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return cmuxEnvironment(processArguments: Array(buffer.prefix(size)))
    }

    static func cmuxEnvironment(processArguments buffer: [UInt8]) -> [String: String]? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var offset = MemoryLayout<Int32>.size
        while offset < buffer.count && buffer[offset] != 0 { offset += 1 }
        while offset < buffer.count && buffer[offset] == 0 { offset += 1 }
        for _ in 0..<argc {
            while offset < buffer.count && buffer[offset] != 0 { offset += 1 }
            guard offset < buffer.count else { return nil }
            offset += 1
        }
        var result: [String: String] = [:]
        while offset < buffer.count {
            let start = offset
            while offset < buffer.count && buffer[offset] != 0 { offset += 1 }
            let entry = String(decoding: buffer[start..<offset], as: UTF8.self)
            if let separator = entry.firstIndex(of: "=") {
                let key = String(entry[..<separator])
                if key == "CMUX_SURFACE_ID" || key == "CMUX_WORKSPACE_ID" {
                    result[key] = String(entry[entry.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            offset += 1
        }
        return result
    }
}
