import Foundation
import Darwin

/// The bridge's log, /tmp/codeisland-bridge.log (`CODEISLAND_BRIDGE_LOG`
/// moves it: the tests that run the bridge point it at a file of theirs).
///
/// A line per hook says what the hook was — its event, source, session,
/// tool and the names of the fields it carried — and never what it said:
/// prompts, commands, tool input and output stay out of it. The whole
/// payload is logged too only with `CODEISLAND_DEBUG=1`, for a session of
/// debugging. Past ~5 MB the log moves to `.1`, replacing the one before,
/// and starts over, so it stays bounded either way.
///
/// The path is a predictable name in /tmp, which another user can take
/// first: with a file of theirs, a link to a file of ours, or a FIFO that
/// would hang the hook. So it is written only as a regular file of this
/// user's that nothing else links to, never through a symlink, and readable
/// by nobody else; the `.1` it moves to is that same file.
public struct BridgeLog {
    public static let defaultPath = "/tmp/codeisland-bridge.log"
    public static let defaultMaxBytes = 5 * 1024 * 1024

    public let path: String
    /// `CODEISLAND_DEBUG=1`: whole payloads are logged too.
    public let logsPayloads: Bool
    public let maxBytes: Int

    public init(environment: [String: String], maxBytes: Int = BridgeLog.defaultMaxBytes) {
        let override = environment["CODEISLAND_BRIDGE_LOG"] ?? ""
        path = override.isEmpty ? Self.defaultPath : override
        logsPayloads = environment["CODEISLAND_DEBUG"] == "1"
        self.maxBytes = maxBytes
    }

    /// Logs a line that says what happened, never what a hook said.
    public func note(_ message: String, at date: Date = Date()) {
        Self.append("[\(ISO8601DateFormatter().string(from: date))] \(message)\n", to: path, maxBytes: maxBytes)
    }

    /// Logs a hook's content, only under `CODEISLAND_DEBUG=1`.
    public func payload(_ message: @autoclosure () -> String, at date: Date = Date()) {
        guard logsPayloads else { return }
        note(message(), at: date)
    }

    /// The line a hook leaves: what it was, never what it said. Each part
    /// is the hook's own (a session id, a tool name), so it is kept to one
    /// line of printable text and cut short.
    public static func hookLine(
        eventName: String,
        normalizedEventName: String,
        source: String?,
        sessionId: String,
        toolName: String?,
        payloadKeys: [String],
        blocking: Bool
    ) -> String {
        [
            "hook event=\(field(eventName))",
            "normalized=\(field(normalizedEventName))",
            "source=\(field(source ?? "-"))",
            "session=\(field(sessionId))",
            "tool=\(field(toolName ?? "-"))",
            "keys=\(keyList(payloadKeys))",
            "blocking=\(blocking)",
        ].joined(separator: " ")
    }

    /// The names of a payload's fields, sorted, without their values.
    public static func keyList(_ keys: [String]) -> String {
        let shown = keys.sorted().prefix(maxKeys).map { field($0, limit: 64) }
        return shown.joined(separator: ",") + (keys.count > maxKeys ? ",…" : "")
    }

    private static let maxKeys = 40

    /// `value` as printable text on one line: control characters (a newline
    /// would forge a line of its own, an escape would reach whoever reads
    /// the log in a terminal) and spaces become `_`, cut at `limit`.
    public static func field(_ value: String, limit: Int = 128) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            return v <= 0x20 || (0x7F...0x9F).contains(v) ? "_" : Character(scalar)
        }
        let text = String(scalars)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: - Writing

    /// Appends `line`, first moving a log that would grow past `maxBytes`
    /// to `<path>.1`. When that cannot be done (`.1` is another user's in
    /// sticky /tmp) the log starts over in place instead.
    static func append(_ line: String, to path: String, maxBytes: Int) {
        guard var fd = openPrivately(path) else { return }
        let bytes = Array(line.utf8)
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 0, Int(info.st_size) + bytes.count > maxBytes {
            rotate(path, opened: info, fd: fd)
            close(fd)
            guard let fresh = openPrivately(path) else { return }
            fd = fresh
        }
        defer { close(fd) }
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The log, opened to append: a regular file of this user's that nothing
    /// else links to, reached without following a symlink and narrowed to
    /// 0600 if it was not. Nil for anything else, and for a FIFO without
    /// waiting on one.
    private static func openPrivately(_ path: String) -> Int32? {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            return nil
        }
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        return fd
    }

    /// Moves the log this process opened to `.1`: only if the path still
    /// names it (another hook may have moved it first), and over whatever
    /// `.1` holds, which rename replaces rather than writes through.
    private static func rotate(_ path: String, opened info: stat, fd: Int32) {
        guard let current = SocketPath.lstat(path),
              current.st_dev == info.st_dev, current.st_ino == info.st_ino else { return }
        if rename(path, path + ".1") != 0 {
            ftruncate(fd, 0)
        }
    }
}
