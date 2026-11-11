import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Each remote host's hooks arrive on a socket the island binds for that host
/// alone, in a folder only this user can enter: made when the host connects,
/// gone when it disconnects, and never one another user could have put there.
/// Every socket and folder here is a throwaway under /tmp — never the user's.
@MainActor
final class RemoteHookSocketsTests: XCTestCase {
    private var base: String!
    private var folder: String!
    private var appState: AppState!
    private var sockets: RemoteHookSockets?

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        base = "/tmp/ci-rhs-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: false)
        folder = base + "/hosts"
        appState = AppState()
    }

    override func tearDownWithError() throws {
        sockets?.closeAll()
        sockets = nil
        appState = nil
        // A test may have left the folder without write permission.
        chmod(folder, 0o700)
        try? FileManager.default.removeItem(atPath: base)
    }

    private func makeSockets(
        in directory: String? = nil,
        legacy: String? = nil,
        cwdFilter: @escaping @MainActor (String) -> String? = { _ in nil }
    ) -> RemoteHookSockets {
        let appState = appState!
        let made = RemoteHookSockets(directory: directory ?? folder, legacyDirectory: legacy) { path, origin in
            HookServer(appState: appState, socketPath: path, origin: origin, hostCwdFilter: cwdFilter)
        }
        sockets = made
        return made
    }

    private func host(_ id: String, name: String = "Dev Box") -> RemoteHost {
        RemoteHost(id: id, name: name, host: "\(id).invalid")
    }

    private func pump(
        until condition: () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message, file: file, line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// What the island answers `payload` on the socket at `path`; nil when
    /// nothing listens there.
    private func exchange(_ payload: String, at path: String, file: StaticString = #filePath, line: UInt = #line) -> Data? {
        let exchange = HookExchange.send(Data(payload.utf8), to: path)
        pump(until: { exchange.isDone }, "no answer from \(path)", file: file, line: line)
        return exchange.answer
    }

    // MARK: - Lifecycle

    func testAConnectingHostGetsASocketOfItsOwnInAPrivateFolder() throws {
        let sockets = makeSockets()
        let path = try sockets.open(for: host("host-a")).get()

        XCTAssertEqual(path, folder + "/" + RemoteHookSockets.socketName(forHostId: "host-a"))
        XCTAssertNotEqual(path, HookServer.socketPath)
        XCTAssertEqual(sockets.openPath(forHostId: "host-a"), path)
        let socketFile = try XCTUnwrap(SocketPath.lstat(path))
        XCTAssertEqual(socketFile.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(socketFile.st_uid, getuid())
        XCTAssertEqual(socketFile.st_mode & 0o077, 0, "nobody else may connect")
        let folderInfo = try XCTUnwrap(SocketPath.lstat(folder))
        XCTAssertEqual(folderInfo.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(folderInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(folderInfo.st_uid, getuid())
        XCTAssertNotNil(exchange(#"{"hook_event_name":"Stop","session_id":"s1"}"#, at: path), "it listens")
    }

    func testAHostsSocketGoesTheMomentItDisconnects() throws {
        let sockets = makeSockets()
        let path = try sockets.open(for: host("host-a")).get()
        sockets.close(hostId: "host-a")
        XCTAssertNil(SocketPath.lstat(path), "removed at once: the host may bind it again right away")
        XCTAssertNil(sockets.openPath(forHostId: "host-a"))

        // The island quitting closes every one.
        let first = try sockets.open(for: host("host-a")).get()
        let second = try sockets.open(for: host("host-b")).get()
        XCTAssertNotEqual(first, second)
        sockets.closeAll()
        XCTAssertNil(SocketPath.lstat(first))
        XCTAssertNil(SocketPath.lstat(second))
    }

    /// Every connect binds afresh: a socket file removed from under a live
    /// listener would otherwise leave the host unreachable until a restart.
    func testReconnectingBindsTheSocketAfresh() throws {
        let sockets = makeSockets()
        let path = try sockets.open(for: host("host-a")).get()
        unlink(path)
        XCTAssertEqual(try sockets.open(for: host("host-a")).get(), path)
        XCTAssertNotNil(SocketPath.lstat(path))
        _ = exchange(#"{"hook_event_name":"UserPromptSubmit","session_id":"again","cwd":"/w","prompt":"p","_source":"claude"}"#, at: path)
        pump(until: { self.appState.sessions["remote:host-a:again"] != nil }, "the event never reached the island")
    }

    /// The listener removes the socket file it made, and not one that has
    /// taken its place since: a host bound anew must keep its socket.
    func testAListenerRemovesOnlyItsOwnSocketFile() throws {
        let path = base + "/l.sock"
        let listener = HookSocketListener(path: path, queue: DispatchQueue(label: "ci-rhs")) { $0.cancel() }
        XCTAssertTrue(listener.start())
        unlink(path)
        try leaveSocket(at: path)
        listener.removeSocketFile()
        XCTAssertNotNil(SocketPath.lstat(path), "a socket that took its place is not the listener's to remove")
        listener.stop()

        unlink(path)
        let own = HookSocketListener(path: path, queue: DispatchQueue(label: "ci-rhs")) { $0.cancel() }
        XCTAssertTrue(own.start())
        own.removeSocketFile()
        XCTAssertNil(SocketPath.lstat(path))
        own.stop()
    }

    // MARK: - The socket names the host

    /// Whatever a request on a host's socket claims — another host, or none,
    /// which would have made it a session of this Mac — it is that host's.
    func testEveryRequestOnAHostsSocketIsThatHosts() throws {
        let path = try makeSockets().open(for: host("host-a", name: "Dev Box")).get()
        let requests = [
            #"{"hook_event_name":"UserPromptSubmit","session_id":"forged","cwd":"/w","prompt":"p","_source":"claude","_remote_host_id":"host-b","_remote_host_name":"Other Box"}"#,
            #"{"hook_event_name":"UserPromptSubmit","session_id":"bare","cwd":"/w","prompt":"p","_source":"claude"}"#,
            #"{"hook_event_name":"UserPromptSubmit","session_id":"facts","cwd":"/w","prompt":"p","_edge":{"v":1,"source":"claude","waits":false,"host":{"id":"host-b","name":"Other Box"}}}"#,
        ]
        for request in requests {
            _ = exchange(request, at: path)
        }
        let expected: Set<String> = ["remote:host-a:forged", "remote:host-a:bare", "remote:host-a:facts"]
        pump(until: { expected.isSubset(of: Set(self.appState.sessions.keys)) }, "\(appState.sessions.keys.sorted())")
        XCTAssertEqual(Set(appState.sessions.keys), expected, "no session of this Mac's, none of another host's")
        for key in expected {
            let session = try XCTUnwrap(appState.sessions[key])
            XCTAssertTrue(session.isRemote, key)
            XCTAssertEqual(session.remoteHostId, "host-a", key)
            XCTAssertEqual(session.remoteHostName, "Dev Box", key)
        }
    }

    func testARenamedHostsRequestsCarryTheNewName() throws {
        let sockets = makeSockets()
        let path = try sockets.open(for: host("host-a", name: "Dev Box")).get()
        _ = exchange(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/w","prompt":"p","_source":"claude"}"#, at: path)
        pump(until: { self.appState.sessions["remote:host-a:s"]?.remoteHostName == "Dev Box" }, "not filed under the host")

        sockets.rename(hostId: "host-a", to: "Build Box")
        _ = exchange(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/w","prompt":"q","_source":"claude","_remote_host_name":"Dev Box"}"#, at: path)
        pump(until: { self.appState.sessions["remote:host-a:s"]?.remoteHostName == "Build Box" }, "the new name never arrived")
    }

    // MARK: - The folder

    func testAFolderThatIsASymlinkIsRefused() throws {
        let elsewhere = base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        chmod(elsewhere, 0o700)
        try FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: elsewhere)

        XCTAssertEqual(makeSockets().open(for: host("host-a")), .failure(.folderNotPrivate(path: folder)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [], "nothing is made through it")
    }

    func testAFileWhereTheFolderGoesIsRefused() throws {
        FileManager.default.createFile(atPath: folder, contents: Data("x".utf8))
        XCTAssertEqual(makeSockets().open(for: host("host-a")), .failure(.folderNotPrivate(path: folder)))
    }

    func testAnotherUsersFolderIsRefusedAndLeftAsItIs() throws {
        XCTAssertEqual(mkdir(folder, 0o755), 0)
        chmod(folder, 0o755)
        XCTAssertFalse(RemoteHookSockets.preparePrivateFolder(folder, uid: getuid() + 1))
        XCTAssertEqual(try XCTUnwrap(SocketPath.lstat(folder)).st_mode & 0o777, 0o755, "not narrowed: not ours")
    }

    func testOurOwnFolderOpenToOthersIsNarrowed() throws {
        XCTAssertEqual(mkdir(folder, 0o700), 0)
        chmod(folder, 0o777)
        XCTAssertNoThrow(try makeSockets().open(for: host("host-a")).get())
        XCTAssertEqual(try XCTUnwrap(SocketPath.lstat(folder)).st_mode & 0o777, 0o700)
    }

    func testAHostSocketThatCannotBeBoundFails() throws {
        let deep = base + "/" + String(repeating: "d", count: 90)
        let sockets = makeSockets(in: deep)
        let expected = deep + "/" + RemoteHookSockets.socketName(forHostId: "host-a")
        XCTAssertEqual(sockets.open(for: host("host-a")), .failure(.cannotListen(path: expected)))
        XCTAssertNil(sockets.openPath(forHostId: "host-a"))
    }

    /// A host without an id gets no socket: one would name no host, and its
    /// requests pass for this Mac's.
    func testAHostWithoutAnIdGetsNoSocket() throws {
        let sockets = makeSockets()
        for id in ["", "   "] {
            XCTAssertEqual(sockets.open(for: host(id)), .failure(.cannotListen(path: folder)))
            XCTAssertNil(sockets.openPath(forHostId: id))
            XCTAssertNil(SocketPath.lstat(sockets.path(forHostId: id)))
        }
    }

    // MARK: - Stale sockets

    /// A crash leaves its hosts' sockets behind; the next launch removes
    /// them — only sockets of this user's under a host socket's name, never
    /// through a symlink, and never one a host of this run has open.
    func testSocketsAnEarlierRunLeftBehindAreRemoved() throws {
        let sockets = makeSockets()
        let live = try sockets.open(for: host("host-a")).get()
        let stale = folder + "/h-0123456789abcdef.sock"
        try leaveSocket(at: stale)
        let notASocket = folder + "/h-1111111111111111.sock"
        FileManager.default.createFile(atPath: notASocket, contents: Data())
        let target = base + "/target.sock"
        try leaveSocket(at: target)
        let link = folder + "/h-2222222222222222.sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let otherName = folder + "/notes.sock"
        try leaveSocket(at: otherName)

        sockets.removeStale()

        XCTAssertNil(SocketPath.lstat(stale), "a stale host socket is removed")
        XCTAssertNotNil(SocketPath.lstat(notASocket), "not a socket: left")
        XCTAssertNotNil(SocketPath.lstat(link), "a symlink: left")
        XCTAssertNotNil(SocketPath.lstat(target), "and never followed")
        XCTAssertNotNil(SocketPath.lstat(otherName), "not a host socket's name: left")
        XCTAssertNotNil(SocketPath.lstat(live), "this run's: left")
        XCTAssertNotNil(exchange(#"{"hook_event_name":"Stop","session_id":"s"}"#, at: live), "and still listening")
    }

    func testStaleSocketsAreLeftInAFolderThatIsNotOurs() throws {
        XCTAssertTrue(RemoteHookSockets.preparePrivateFolder(folder))
        let stale = folder + "/h-0123456789abcdef.sock"
        try leaveSocket(at: stale)
        makeSockets().removeStale(uid: getuid() + 1)
        XCTAssertNotNil(SocketPath.lstat(stale))

        // No folder yet: nothing to do, and none is made.
        try FileManager.default.removeItem(atPath: folder)
        makeSockets().removeStale()
        XCTAssertNil(SocketPath.lstat(folder))
    }

    // MARK: - Names

    func testHostSocketNamesAreShortAndStable() {
        let long = String(repeating: "x", count: 500)
        let name = RemoteHookSockets.socketName(forHostId: long)
        XCTAssertEqual(name.count, "h-".count + 16 + ".sock".count)
        XCTAssertEqual(name, RemoteHookSockets.socketName(forHostId: long), "the same on every connect")
        XCTAssertTrue(RemoteHookSockets.isSocketName(name))
        XCTAssertNotEqual(RemoteHookSockets.socketName(forHostId: "a"), RemoteHookSockets.socketName(forHostId: "b"))
        XCTAssertFalse(RemoteHookSockets.socketName(forHostId: "../../etc/x").contains("/"))
        // The default folder for the highest uid still leaves sun_path room.
        let path = RemoteHookSockets.directory(forMainSocket: "/tmp/codeisland-4294967294.sock") + "/" + name
        XCTAssertLessThan(path.utf8.count, 104)

        for other in ["h-0123456789ABCDEF.sock", "h-0123.sock", "x-0123456789abcdef.sock",
                      "h-0123456789abcdef.sock.bak", "h-\u{FF10}123456789abcdef.sock", "notes.sock"] {
            XCTAssertFalse(RemoteHookSockets.isSocketName(other), other)
        }
    }

    func testTheHostsFolderSitsBesideTheMainSocket() {
        XCTAssertEqual(RemoteHookSockets.directory(forMainSocket: "/tmp/codeisland-501.sock"), "/tmp/codeisland-501-hosts")
        XCTAssertEqual(RemoteHookSockets.directory(forMainSocket: "/tmp/ci/island"), "/tmp/ci/island-hosts")
    }

    // MARK: - Where the folder is

    /// The island's hosts folder is in the user's own temporary folder, not
    /// a name in /tmp another user could take first; the one in /tmp an
    /// earlier version used is the one to clear away.
    func testTheHostsFolderIsInTheUsersOwnTemporaryFolder() {
        let folders = RemoteHookSockets.defaultFolders(
            mainSocket: "/tmp/codeisland-501.sock",
            environment: [:],
            userTemporaryDirectory: "/var/folders/ab/cdefgh0123456789abcdefghijk/T"
        )
        XCTAssertEqual(folders.directory, "/var/folders/ab/cdefgh0123456789abcdefghijk/T/codeisland-hosts")
        XCTAssertEqual(folders.legacy, "/tmp/codeisland-501-hosts")
    }

    /// An island on a socket of its own (an isolated instance) keeps its
    /// hosts beside it, apart from the installed island's; and an unknown,
    /// or too long, temporary folder leaves them beside the main socket too.
    func testAnIsolatedIslandKeepsItsHostsBesideItsSocket() {
        let isolated = RemoteHookSockets.defaultFolders(
            mainSocket: "/tmp/ci-dev/island.sock",
            environment: ["CODEISLAND_SOCKET_PATH": "/tmp/ci-dev/island.sock"],
            userTemporaryDirectory: "/var/folders/ab/cd/T"
        )
        XCTAssertEqual(isolated.directory, "/tmp/ci-dev/island-hosts")
        XCTAssertNil(isolated.legacy)

        let unknown = RemoteHookSockets.defaultFolders(mainSocket: "/tmp/codeisland-501.sock", environment: [:], userTemporaryDirectory: nil)
        XCTAssertEqual(unknown.directory, "/tmp/codeisland-501-hosts")
        XCTAssertNil(unknown.legacy)

        let long = "/var/folders/" + String(repeating: "x", count: 70)
        let tooLong = RemoteHookSockets.defaultFolders(mainSocket: "/tmp/codeisland-501.sock", environment: [:], userTemporaryDirectory: long)
        XCTAssertEqual(tooLong.directory, "/tmp/codeisland-501-hosts", "a socket there would not fit sun_path")
    }

    /// This Mac's own temporary folder is this user's alone, and a host
    /// socket in the folder made there fits sun_path.
    func testThisMacsTemporaryFolderHoldsTheHostSockets() throws {
        let temporary = try XCTUnwrap(RemoteHookSockets.userTemporaryDirectory())
        XCTAssertFalse(temporary.hasSuffix("/"))
        let info = try XCTUnwrap(SocketPath.lstat(temporary))
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o077, 0, "others may enter \(temporary)")
        let folders = RemoteHookSockets.defaultFolders(mainSocket: "/tmp/codeisland-501.sock", environment: [:])
        XCTAssertEqual(folders.directory, temporary + "/codeisland-hosts")
        XCTAssertLessThan((folders.directory + "/" + RemoteHookSockets.socketName(forHostId: "any")).utf8.count, 104)
    }

    /// The folder an earlier version used in /tmp goes: its stale sockets
    /// first, then the folder itself, once nothing else is left in it.
    func testTheOldFolderInTmpIsClearedAway() throws {
        let legacy = base + "/old-hosts"
        XCTAssertTrue(RemoteHookSockets.preparePrivateFolder(legacy))
        try leaveSocket(at: legacy + "/h-0123456789abcdef.sock")
        try leaveSocket(at: legacy + "/h-1111111111111111.sock")

        makeSockets(legacy: legacy).removeStale()
        XCTAssertNil(SocketPath.lstat(legacy), "the old folder was left")

        // Something else in it: the sockets go, the folder and the rest stay.
        XCTAssertTrue(RemoteHookSockets.preparePrivateFolder(legacy))
        try leaveSocket(at: legacy + "/h-0123456789abcdef.sock")
        XCTAssertTrue(FileManager.default.createFile(atPath: legacy + "/notes.txt", contents: Data()))
        makeSockets(legacy: legacy).removeStale()
        XCTAssertNil(SocketPath.lstat(legacy + "/h-0123456789abcdef.sock"))
        XCTAssertNotNil(SocketPath.lstat(legacy + "/notes.txt"))
        XCTAssertNotNil(SocketPath.lstat(legacy))
    }

    /// Only an old folder of this user's is cleared: another user's, or a
    /// symlink where it was, is left as it is.
    func testAnOldFolderThatIsNotOursIsLeftAlone() throws {
        let legacy = base + "/old-hosts"
        XCTAssertTrue(RemoteHookSockets.preparePrivateFolder(legacy))
        let stale = legacy + "/h-0123456789abcdef.sock"
        try leaveSocket(at: stale)
        makeSockets(legacy: legacy).removeStale(uid: getuid() + 1)
        XCTAssertNotNil(SocketPath.lstat(stale), "another user's old folder was cleared")

        let link = base + "/linked-hosts"
        XCTAssertEqual(symlink(legacy, link), 0)
        makeSockets(legacy: link).removeStale()
        XCTAssertNotNil(SocketPath.lstat(stale), "cleared through a symlink")
        XCTAssertNotNil(SocketPath.lstat(link))
    }
}
