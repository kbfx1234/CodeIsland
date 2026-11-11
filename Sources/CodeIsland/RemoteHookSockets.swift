import CryptoKit
import Darwin
import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "RemoteHookSockets")

/// Why a remote host has no socket of its own, and so does not connect.
enum RemoteHookSocketFailure: Error, Equatable {
    /// The folder the host sockets go in is not one only this user can use:
    /// another user's, a symlink, a file.
    case folderNotPrivate(path: String)
    /// The island cannot listen at `path`.
    case cannotListen(path: String)

    /// What Settings → Remote shows for the host.
    func message(_ l10n: L10n) -> String {
        switch self {
        case .folderNotPrivate(let path):
            return String(format: l10n["remote_socket_folder_unsafe"], path)
        case .cannotListen(let path):
            return String(format: l10n["remote_socket_unavailable"], path)
        }
    }
}

/// Where each remote host's hooks arrive on this Mac: `RemoteHookSockets`,
/// or a stand-in in tests.
@MainActor
protocol RemoteHookSocketProviding: AnyObject {
    /// Binds a socket for `host` — a fresh one, closing any it had — and
    /// returns its path: the only place the host's forward may end.
    func open(for host: RemoteHost) -> Result<String, RemoteHookSocketFailure>
    /// The host was renamed: its requests carry the new name.
    func rename(hostId: String, to name: String)
    /// Closes the host's socket and removes its file.
    func close(hostId: String)
    /// Closes every host's socket.
    func closeAll()
    /// Removes the sockets an earlier run left behind.
    func removeStale()
}

/// A socket of its own for each connected remote host, bound by the island
/// when the host connects, at the Mac's end of the host's SSH forward. Every
/// request on it is that host's (``HookOrigin``) — whatever the payload
/// says — and a forward never ends at a path the island did not just bind:
/// not at the main socket, which another user may have taken first.
///
/// The sockets live in a folder only this user can enter: `codeisland-hosts`
/// in the user's own temporary folder (`/var/folders/…/T/`), which nobody
/// else can enter or make anything in first — not a predictable name in
/// /tmp, where another user could take it and keep every host from
/// connecting. An island on a socket of its own (`CODEISLAND_SOCKET_PATH`,
/// an isolated instance) keeps its hosts apart beside that socket instead.
/// Each is named after a digest of its host's id (`h-<16 hex>.sock`): the
/// same on every connect, short enough for `sun_path` whatever the id, and
/// nothing an id can steer out of the folder. A socket goes when its host
/// disconnects or is removed, or the island quits; one a crash left behind
/// goes at the next launch (``removeStale()``), and so does the folder in
/// /tmp an earlier version used.
@MainActor
final class RemoteHookSockets: RemoteHookSocketProviding {
    /// The folder the sockets are in.
    let directory: String
    /// The folder an earlier version put them in, when it is another:
    /// emptied of its sockets and removed (``removeStale()``).
    let legacyDirectory: String?
    private let makeServer: (_ path: String, _ origin: HookOrigin) -> HookServer
    /// By host id.
    private var servers: [String: HookServer] = [:]

    /// `makeServer` makes the server for a host's socket; it is started
    /// here.
    init(
        directory: String,
        legacyDirectory: String? = nil,
        makeServer: @escaping (_ path: String, _ origin: HookOrigin) -> HookServer
    ) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory == directory ? nil : legacyDirectory
        self.makeServer = makeServer
    }

    /// The island's: each host's server hands what it receives to `appState`.
    convenience init(
        appState: AppState,
        folders: (directory: String, legacy: String?) = RemoteHookSockets.defaultFolders()
    ) {
        self.init(directory: folders.directory, legacyDirectory: folders.legacy) { path, origin in
            HookServer(appState: appState, socketPath: path, origin: origin)
        }
    }

    /// The folder for host sockets beside the main socket at `path`: its
    /// name without `.sock`, plus `-hosts`.
    nonisolated static func directory(forMainSocket path: String) -> String {
        let base = path.hasSuffix(".sock") ? String(path.dropLast(".sock".count)) : path
        return base + "-hosts"
    }

    /// Where the island's host sockets go, and the folder an earlier version
    /// put them in when that is another: `codeisland-hosts` in the user's
    /// temporary folder, then, and the one beside the main socket in /tmp.
    /// Beside the main socket when `CODEISLAND_SOCKET_PATH` names one of its
    /// own, or the temporary folder is unknown or too long a path for a
    /// socket in it.
    nonisolated static func defaultFolders(
        mainSocket: String = HookServer.socketPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userTemporaryDirectory: String? = RemoteHookSockets.userTemporaryDirectory()
    ) -> (directory: String, legacy: String?) {
        let beside = directory(forMainSocket: mainSocket)
        guard environment["CODEISLAND_SOCKET_PATH"] == nil,
              let userTemporaryDirectory, userTemporaryDirectory.hasPrefix("/") else {
            return (beside, nil)
        }
        let own = (userTemporaryDirectory == "/" ? "" : userTemporaryDirectory) + "/codeisland-hosts"
        // sun_path holds 104 bytes, its NUL among them.
        let longestSocket = own.utf8.count + 1 + socketName(forHostId: "").utf8.count
        guard longestSocket < 104 else { return (beside, nil) }
        return (own, beside)
    }

    /// This user's own temporary folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`),
    /// without its trailing slash; nil when there is none.
    nonisolated static func userTemporaryDirectory() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) == size else { return nil }
        var path = String(cString: buffer)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? nil : path
    }

    /// The socket name for the host `id`: `h-` and the first 8 bytes of the
    /// id's SHA-256, in hex.
    nonisolated static func socketName(forHostId id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return "h-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    /// Whether `name` is one ``socketName(forHostId:)`` gives.
    nonisolated static func isSocketName(_ name: String) -> Bool {
        guard name.hasPrefix("h-"), name.hasSuffix(".sock") else { return false }
        let digest = name.dropFirst(2).dropLast(".sock".count)
        return digest.count == 16 && digest.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Where the host `id`'s socket is.
    func path(forHostId id: String) -> String {
        directory + "/" + Self.socketName(forHostId: id)
    }

    /// Whether the host has a socket open, and where.
    func openPath(forHostId id: String) -> String? {
        servers[id]?.socketPath
    }

    func open(for host: RemoteHost) -> Result<String, RemoteHookSocketFailure> {
        // Bound afresh on every connect: a socket file removed from under a
        // live listener would otherwise leave the host unreachable for good.
        close(hostId: host.id)
        // A host without an id names nobody: its requests would pass for
        // this Mac's.
        guard !HookOrigin.isBlankHostId(host.id) else {
            log.error("A remote host without an id gets no socket")
            return .failure(.cannotListen(path: directory))
        }
        guard Self.preparePrivateFolder(directory) else {
            return .failure(.folderNotPrivate(path: directory))
        }
        let path = path(forHostId: host.id)
        // Two ids with one digest would share a socket, and each other's
        // requests: neither gets this one.
        guard !servers.values.contains(where: { $0.socketPath == path }) else {
            log.error("Two remote hosts' sockets would share \(path, privacy: .public)")
            return .failure(.cannotListen(path: path))
        }
        let server = makeServer(path, .remoteHost(id: host.id, name: host.name))
        guard server.start() else {
            return .failure(.cannotListen(path: path))
        }
        servers[host.id] = server
        log.info("Listening for remote host \(host.id, privacy: .public) at \(path, privacy: .public)")
        return .success(path)
    }

    func rename(hostId: String, to name: String) {
        servers[hostId]?.renameHost(to: name)
    }

    func close(hostId: String) {
        guard let server = servers.removeValue(forKey: hostId) else { return }
        server.stop()
    }

    func closeAll() {
        for hostId in Array(servers.keys) {
            close(hostId: hostId)
        }
    }

    /// Removes the host sockets an earlier run left behind (a crash, or a
    /// quit that never closed them). Only in the folder, and only while it is
    /// still one only this user can use; only sockets of this user's, under
    /// a name a host socket takes, and never one of this run's. The folder an
    /// earlier version used (``legacyDirectory``) is emptied the same way and
    /// removed, should nothing else be left in it.
    func removeStale() {
        removeStale(uid: getuid())
    }

    /// ``removeStale()`` as the user `uid`: for tests, which cannot make a
    /// file another user owns.
    func removeStale(uid: uid_t) {
        let open = Set(servers.values.map { ($0.socketPath as NSString).lastPathComponent })
        Self.removeSockets(in: directory, uid: uid, keeping: open)
        if let legacyDirectory, Self.removeSockets(in: legacyDirectory, uid: uid, keeping: []),
           rmdir(legacyDirectory) == 0 {
            // A folder of this user's in sticky /tmp: nobody else can have
            // put another in its place since it was checked.
            log.info("Removed the old remote host socket folder \(legacyDirectory, privacy: .public)")
        }
    }

    /// Removes the host sockets in the folder at `path` but those named in
    /// `keeping`; false, touching nothing, when it is not a private folder of
    /// `uid`'s, or not there.
    @discardableResult
    nonisolated private static func removeSockets(in path: String, uid: uid_t, keeping: Set<String>) -> Bool {
        guard let folder = openPrivateFolder(path, creating: false, uid: uid) else { return false }
        defer { Darwin.close(folder) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for name in names where isSocketName(name) && !keeping.contains(name) {
            // Relative to the folder checked above, never followed.
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFSOCK,
                  info.st_uid == uid else { continue }
            if unlinkat(folder, name, 0) == 0 {
                log.info("Removed a stale remote host socket: \(name, privacy: .public)")
            }
        }
        return true
    }

    // MARK: - The folder

    /// Makes `path` a folder only this user can use, or finds it one: it is
    /// created 0700, or it is already a folder — not a symlink to one — this
    /// user owns, whose mode is narrowed to 0700 if it let anyone else in.
    /// False, logged, for anything else: whatever another user put there, a
    /// symlink, a file. Nothing is created inside it until it passes. `uid`
    /// is for tests, which cannot make a folder another user owns.
    nonisolated static func preparePrivateFolder(_ path: String, uid: uid_t = getuid()) -> Bool {
        guard let folder = openPrivateFolder(path, creating: true, uid: uid) else { return false }
        Darwin.close(folder)
        return true
    }

    /// The folder at `path`, opened, once it is a private folder of `uid`'s
    /// (``preparePrivateFolder(_:uid:)``); nil when it is not, or is not
    /// there and `creating` is false.
    nonisolated private static func openPrivateFolder(_ path: String, creating: Bool, uid: uid_t) -> Int32? {
        if creating, mkdir(path, 0o700) != 0, errno != EEXIST {
            log.error("Cannot create \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        // O_NOFOLLOW: a symlink at `path`, whoever made it, is refused, not
        // followed; the checks and the chmod below act on what was opened.
        let folder = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            if creating || errno != ENOENT {
                log.error("\(path, privacy: .public) is not a folder CodeIsland can use for remote host sockets: \(String(cString: strerror(errno)), privacy: .public)")
            }
            return nil
        }
        var info = stat()
        guard fstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            log.error("Cannot read \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            Darwin.close(folder)
            return nil
        }
        guard info.st_uid == uid else {
            log.error("\(path, privacy: .public) belongs to uid \(info.st_uid), not this user: no remote host socket goes there")
            Darwin.close(folder)
            return nil
        }
        if info.st_mode & 0o077 != 0, fchmod(folder, 0o700) != 0 {
            log.error("Cannot make \(path, privacy: .public) private: \(String(cString: strerror(errno)), privacy: .public)")
            Darwin.close(folder)
            return nil
        }
        return folder
    }
}
