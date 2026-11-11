import Foundation
import Darwin

public enum SocketPath {
    public static var path: String {
        if let env = ProcessInfo.processInfo.environment["CODEISLAND_SOCKET_PATH"] {
            return env
        }
        return "/tmp/codeisland-\(getuid()).sock"
    }

    /// Who holds a socket path, as `lstat` sees it.
    ///
    /// The default path is a predictable name in /tmp, where any user can
    /// create a file first. A socket someone else put there would be sent
    /// every hook's payload (prompts, commands, file contents) and could
    /// answer a permission request: allow it, and rewrite the tool's input.
    /// So a hook talks only to a socket this user owns, and the island says
    /// so when the path is taken (`HookSocketHealth`).
    ///
    /// Once a socket this user owns is found in /tmp, nobody else can swap
    /// it: only a file's owner can remove or rename it in a sticky folder.
    /// Elsewhere (`CODEISLAND_SOCKET_PATH`) ``peerIsUser(_:uid:)`` checks the
    /// listener itself once connected.
    public enum Holder: Equatable, Sendable {
        /// A socket this user owns: the only thing a hook talks to.
        case thisUser
        /// Nothing there, or nothing this user can look at.
        case nobody
        /// Something this user owns that is not a socket: a file, a folder,
        /// or a symlink. Even a symlink to this user's own socket: whoever
        /// owns a symlink can point it elsewhere.
        case notASocket
        /// Anything another user owns, socket or not.
        case otherUser(uid_t)
    }

    /// Who holds `path`. `uid` and `lstat` are for tests, which cannot
    /// create a file another user owns.
    public static func holder(
        of path: String,
        uid: uid_t = getuid(),
        lstat: (String) -> stat? = SocketPath.lstat
    ) -> Holder {
        guard let info = lstat(path) else { return .nobody }
        guard info.st_uid == uid else { return .otherUser(info.st_uid) }
        return (info.st_mode & S_IFMT) == S_IFSOCK ? .thisUser : .notASocket
    }

    /// `lstat(2)`: what the path's last component is itself, never what a
    /// symlink there points to. Nil when it cannot be read.
    public static func lstat(_ path: String) -> stat? {
        var info = stat()
        return Darwin.lstat(path, &info) == 0 ? info : nil
    }

    /// Whether the listener at the other end of a connected Unix socket ran
    /// as `uid` when it called listen(). The file ``holder(of:uid:lstat:)``
    /// checked may have been swapped by the time a hook connects where the
    /// folder is not sticky; the listener's credentials cannot be.
    public static func peerIsUser(_ socket: Int32, uid: uid_t = getuid()) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(socket, &peerUID, &peerGID) == 0 else { return false }
        return peerUID == uid
    }
}
