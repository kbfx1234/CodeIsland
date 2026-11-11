import Darwin
import XCTest
@testable import CodeIslandCore

/// A hook sends only to a socket this user owns (`SocketPath.Holder`): the
/// default path is a predictable name in /tmp, which another user can take
/// first. On a real filesystem, and, for a file another user owns, through an
/// injected lstat: a test cannot chown.
final class SocketPathHolderTests: XCTestCase {
    private var dir: String!
    private var descriptors: [Int32] = []

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        dir = "/tmp/ci-sown-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        descriptors.forEach { close($0) }
        descriptors = []
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// lstat, as if `uid` owned whatever is at the path.
    private static func owned(by uid: uid_t) -> (String) -> stat? {
        { path in
            guard var info = SocketPath.lstat(path) else { return nil }
            info.st_uid = uid
            return info
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        return address
    }

    /// A socket listening at `path`, closed at teardown.
    @discardableResult
    private func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        descriptors.append(fd)
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            throw XCTSkip("cannot listen at \(path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    /// A socket connected to `path`, closed at teardown; nil when it cannot connect.
    private func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        descriptors.append(fd)
        var address = Self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0 ? fd : nil
    }

    func testASocketThisUserOwnsIsTheirs() throws {
        let path = dir + "/island.sock"
        try listen(at: path)
        XCTAssertEqual(SocketPath.holder(of: path), .thisUser)
    }

    func testWhatAnotherUserOwnsAtThePathIsTheirs() throws {
        let path = dir + "/island.sock"
        try listen(at: path)
        let other = getuid() + 1
        XCTAssertEqual(SocketPath.holder(of: path, lstat: Self.owned(by: other)), .otherUser(other))
        // Seen by another user, this user's socket is not theirs either.
        XCTAssertEqual(SocketPath.holder(of: path, uid: other), .otherUser(getuid()))
        // A file they put there holds the path all the same.
        let file = dir + "/file"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))
        XCTAssertEqual(SocketPath.holder(of: file, lstat: Self.owned(by: other)), .otherUser(other))
    }

    /// A real socket another user owns: syslogd's, root's on every Mac.
    func testASystemSocketIsNotThisUsers() throws {
        let path = "/var/run/syslog"
        guard let info = SocketPath.lstat(path), (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid != getuid() else {
            throw XCTSkip("no socket of another user's at \(path)")
        }
        XCTAssertEqual(SocketPath.holder(of: path), .otherUser(info.st_uid))
    }

    func testWhatIsNotASocketIsNotTheIslands() throws {
        let socketPath = dir + "/island.sock"
        try listen(at: socketPath)
        // connect() would follow a symlink to this user's own socket; whoever
        // owns the symlink could point it elsewhere next time.
        let link = dir + "/link.sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: socketPath)
        XCTAssertEqual(SocketPath.holder(of: link), .notASocket)

        let file = dir + "/file.sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))
        XCTAssertEqual(SocketPath.holder(of: file), .notASocket)

        let folder = dir + "/folder.sock"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        XCTAssertEqual(SocketPath.holder(of: folder), .notASocket)
    }

    func testNothingThereIsNobodys() {
        XCTAssertEqual(SocketPath.holder(of: dir + "/missing.sock"), .nobody)
        XCTAssertEqual(SocketPath.holder(of: dir + "/missing/deeper.sock"), .nobody)
        XCTAssertEqual(SocketPath.holder(of: dir + "/island.sock", lstat: { _ in nil }), .nobody)
    }

    func testAListenerThisUserRunsIsTheirs() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        descriptors += pair
        XCTAssertTrue(SocketPath.peerIsUser(pair[0]))
        XCTAssertFalse(SocketPath.peerIsUser(pair[0], uid: getuid() + 1))

        let path = dir + "/island.sock"
        try listen(at: path)
        let client = try XCTUnwrap(connect(to: path))
        XCTAssertTrue(SocketPath.peerIsUser(client))
    }

    func testWhatIsNoConnectedSocketFailsClosed() {
        XCTAssertFalse(SocketPath.peerIsUser(-1))
        let unconnected = socket(AF_UNIX, SOCK_STREAM, 0)
        descriptors.append(unconnected)
        XCTAssertFalse(SocketPath.peerIsUser(unconnected))
    }

    /// A real listener that runs as another user: mDNSResponder, root's on
    /// every Mac. Connected and closed; nothing is sent.
    func testAListenerAnotherUserRunsIsNotThisUsers() throws {
        let path = "/var/run/mDNSResponder"
        guard SocketPath.holder(of: path) != .thisUser, let client = connect(to: path) else {
            throw XCTSkip("cannot connect to \(path)")
        }
        XCTAssertFalse(SocketPath.peerIsUser(client))
    }
}
