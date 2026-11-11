import Foundation
import Darwin

/// Files kept from the other accounts on this Mac.
///
/// `~/.codeisland` holds sessions.json, with every local session's last
/// prompt and reply, beside the hook script and bridge every agent runs. A
/// macOS home folder lets other accounts in (0750 group staff, or 0755), so
/// what CodeIsland writes there is this user's alone: folders 0700, files
/// 0600, 0700 for what agents execute.
///
/// Nothing here follows a symlink at the path it is given, or changes what
/// another user owns: a path is opened with O_NOFOLLOW and judged by what
/// was opened. `uid` is for tests, which cannot make a file another user
/// owns.
public enum PrivateFiles {
    /// Makes `path` a folder only this user can open: created 0700 (missing
    /// parents too), or an existing folder of this user's narrowed to 0700.
    /// False when that is not what is there: a symlink, even to a folder of
    /// this user's, a file, a folder someone else owns.
    @discardableResult
    public static func prepareFolder(_ path: String, uid: uid_t = getuid()) -> Bool {
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return closeToOthers(path, kind: S_IFDIR, uid: uid)
    }

    /// Takes the group's and others' access off a regular file or folder of
    /// this user's at `path`; the owner's stays as it was (0644 → 0600,
    /// 0755 → 0700). A symlink is not followed, and anything else — a
    /// FIFO, a socket, what another user owns — is left as it is. True when
    /// what is at `path` is closed to others now.
    @discardableResult
    public static func closeToOthers(_ path: String, uid: uid_t = getuid()) -> Bool {
        closeToOthers(path, kind: nil, uid: uid)
    }

    private static func closeToOthers(_ path: String, kind: mode_t?, uid: uid_t) -> Bool {
        // O_NONBLOCK: a FIFO someone left at the path does not hang the open.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == uid else { return false }
        let found = info.st_mode & S_IFMT
        guard found == S_IFREG || found == S_IFDIR, kind.map({ $0 == found }) ?? true else { return false }
        guard info.st_mode & 0o077 != 0 else { return true }
        return fchmod(fd, info.st_mode & 0o700) == 0
    }

    /// Writes `data` to `path` as a file only this user can use (`mode`'s
    /// owner bits; anything it gives others is dropped), in one step: a temp
    /// file is created with that mode beside it and then
    /// renamed over `path`. Readers see the old file or the new one, and the
    /// new one is never open to anyone else, even for a moment. A symlink at
    /// `path` is replaced, not followed.
    public static func write(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
        let url = URL(fileURLWithPath: path)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8))")
            .path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode & 0o700)
        guard fd >= 0 else { throw posixError() }
        // The umask may have taken bits off `mode`; it never adds any.
        var failure: POSIXError? = fchmod(fd, mode & 0o700) == 0 ? nil : posixError()
        if failure == nil {
            failure = data.withUnsafeBytes { buffer -> POSIXError? in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return posixError()
                    }
                    offset += n
                }
                return nil
            }
        }
        if close(fd) != 0, failure == nil { failure = posixError() }
        if failure == nil, rename(temp, path) != 0 { failure = posixError() }
        if let failure {
            unlink(temp)
            throw failure
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
