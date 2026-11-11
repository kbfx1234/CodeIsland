import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The hook socket's default path is a predictable name in /tmp, which
/// another user can take first. The island cannot remove their file, so it
/// cannot listen, and hooks send nothing to a socket that isn't this user's:
/// the island must say so, with who holds the path, and listen once it is
/// free. On throwaway paths, never the live socket's; another user's file is
/// an injected lstat, since a test cannot chown.
@MainActor
final class HookSocketHealthTests: XCTestCase {
    private var scratch: String!

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        scratch = "/tmp/ci-sown-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    /// lstat, as if `uid` owned whatever is at the path.
    private static func owned(by uid: uid_t) -> (String) -> stat? {
        { path in
            guard var info = SocketPath.lstat(path) else { return nil }
            info.st_uid = uid
            return info
        }
    }

    /// The island's own socket is a socket of this user's, which nobody else
    /// may open (umask 077 at bind, then chmod 0700).
    func testTheIslandsSocketIsItsUsersAlone() throws {
        let path = scratch + "/island.sock"
        let server = HookServer(appState: AppState(), socketPath: path)
        let health = HookSocketHealth()
        XCTAssertTrue(health.start(server))
        defer { server.stop() }

        XCTAssertNil(health.problem)
        XCTAssertEqual(SocketPath.holder(of: path), .thisUser)
        let info = try XCTUnwrap(SocketPath.lstat(path))
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(info.st_uid, getuid())
    }

    /// Another user's file at the path: the island cannot remove it, cannot
    /// listen, and says who holds it; once the path is free it listens.
    func testAPathAnotherUserHoldsIsReportedWithItsOwner() throws {
        let path = scratch + "/island.sock"
        // What another user would leave there: something the island cannot
        // remove. A folder, since a test cannot chown a file.
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        let other = getuid() + 1
        let server = HookServer(appState: AppState(), socketPath: path)
        let health = HookSocketHealth(lstat: Self.owned(by: other))
        defer { server.stop() }

        XCTAssertFalse(health.start(server))
        XCTAssertEqual(
            health.problem,
            .heldByOtherUser(path: path, uid: other, userName: HookSocketHealth.userName(of: other))
        )
        let detail = HookSocketProblemRow.detail(try XCTUnwrap(health.problem), l10n: L10n.shared)
        XCTAssertTrue(detail.contains(path), detail)
        XCTAssertTrue(detail.contains("uid \(other)"), detail)
        // Never removed or changed: it is not the island's to touch.
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue)

        // Still taken: still reported.
        health.retryIfDown()
        XCTAssertNotNil(health.problem)

        try FileManager.default.removeItem(atPath: path)
        health.retryIfDown()
        XCTAssertNil(health.problem)
        XCTAssertEqual(SocketPath.holder(of: path), .thisUser)
    }

    func testAPathTheIslandCannotListenOnIsReported() throws {
        let path = scratch + "/island.sock"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        let server = HookServer(appState: AppState(), socketPath: path)
        let health = HookSocketHealth()
        defer { server.stop() }

        XCTAssertFalse(health.start(server))
        XCTAssertEqual(health.problem, .cannotListen(path: path))
        XCTAssertTrue(HookSocketProblemRow.detail(.cannotListen(path: path), l10n: L10n.shared).contains(path))
    }

    func testOwnersAreNamedByAccount() {
        XCTAssertEqual(HookSocketHealth.userName(of: getuid()), NSUserName())
        XCTAssertEqual(HookSocketHealth.ownerDescription(uid: 502, userName: "bob"), "bob, uid 502")
        XCTAssertEqual(HookSocketHealth.ownerDescription(uid: 502, userName: nil), "uid 502")
    }
}
