import Foundation
import Darwin

/// Kiro's ACP gateway uses a long-lived, non-interactive `kiro-cli acp`
/// process. Its short-lived protocol sessions are transport internals rather
/// than user-facing terminal conversations.
public enum KiroSessionRouting {
    public static func isACPProcess(arguments: [String]) -> Bool {
        guard let executable = arguments.first,
              ["kiro-cli", "kiro-cli-chat"].contains((executable as NSString).lastPathComponent) else { return false }
        return arguments.dropFirst().first == "acp"
    }

    public static func shouldForwardHook(source: String?, isACPProcess: Bool) -> Bool {
        guard SessionSnapshot.normalizedSupportedSource(source) == "kiro" else { return true }
        return !isACPProcess
    }

    public static func isInternalSession(source: String?, pid: Int32?) -> Bool {
        guard SessionSnapshot.normalizedSupportedSource(source) == "kiro", let pid else { return false }
        return isACPProcess(pid: pid)
    }

    public static func isInternalSession(
        source: String?,
        sessionId: String?,
        pid: Int32?,
        directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/sessions/cli")
    ) -> Bool {
        guard SessionSnapshot.normalizedSupportedSource(source) == "kiro" else { return false }
        if isInternalSession(source: source, pid: pid) { return true }
        guard let sessionId,
              let owner = ownerPID(sessionId: sessionId, in: directory) else { return false }
        return isACPProcess(pid: owner)
    }

    public static func pid(from rawValue: Any?) -> Int32? {
        if let value = rawValue as? Int32 { return value }
        if let value = rawValue as? Int { return Int32(exactly: value) }
        if let value = rawValue as? NSNumber { return value.int32Value }
        return nil
    }

    public static func ownerPID(sessionId: String, in directory: URL) -> Int32? {
        guard UUID(uuidString: sessionId) != nil,
              let data = try? Data(contentsOf: directory.appendingPathComponent(sessionId + ".lock")),
              let lock = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = lock["pid"] as? Int32, pid > 0 else { return nil }
        return pid
    }

    public static func isACPProcess(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 2 else { return false }
        var offset = MemoryLayout<Int32>.size
        while offset < size && buffer[offset] != 0 { offset += 1 }
        while offset < size && buffer[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        // Only argv[0] and the subcommand are needed; never read the environment.
        for _ in 0..<2 {
            let start = offset
            while offset < size && buffer[offset] != 0 { offset += 1 }
            guard offset < size else { return false }
            arguments.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            offset += 1
        }
        return isACPProcess(arguments: arguments)
    }
}
