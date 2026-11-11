import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The island's socket on a remote host sits in a folder only the SSH user
/// can enter, made and checked on the host before anything is forwarded
/// there, and the socket the tunnel makes is checked again once it is up.
/// The scripts that do it run here as they run on a host, with this Mac's
/// python3, beneath a throwaway folder in /tmp instead of /tmp itself.
final class RemoteSocketFolderTests: XCTestCase {
    private var base: String!

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        base = "/tmp/ci-rsf-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(mkdir(base, 0o755), 0)
    }

    override func tearDownWithError() throws {
        // A test may have left a folder without permissions.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for name in names { chmod(base + "/" + name, 0o700) }
        }
        try? FileManager.default.removeItem(atPath: base)
    }

    private var uid: String { String(getuid()) }
    private var folder: String { RemoteInstaller.remoteSocketFolder(forUID: uid, base: base) }

    private struct Run {
        let output: String
        let errorOutput: String
        let exitCode: Int32
    }

    /// Runs `script` with python3, as `getuid` if given (`os.getuid` patched:
    /// a test cannot be another user), after `prelude` (a host's Python, as
    /// a test makes it), the way a host's login shell runs
    /// ``RemoteInstaller/pythonCommand(_:)``.
    private func run(_ script: String, asUID fakeUID: Int? = nil, prelude: String = "", shell: String = "/bin/sh") throws -> Run {
        let program = prelude + (fakeUID.map { "import os\nos.getuid = lambda: \($0)\n" } ?? "") + script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", RemoteInstaller.pythonCommand(program)]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            output: String(decoding: out, as: UTF8.self),
            errorOutput: String(decoding: err, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private func prepare(shared: Bool = false, asUID fakeUID: Int? = nil) throws -> Result<String, RemoteSocketCheckFailure> {
        let script = RemoteInstaller.prepareRemoteSocketFolderScript(agentsRunAsOtherUsers: shared, base: base)
        let ran = try run(script, asUID: fakeUID)
        return RemoteInstaller.preparedSocketPath(fromProbe: ran.output, errorOutput: ran.errorOutput, exitCode: ran.exitCode, base: base)
    }

    /// The check of the socket at `socketPath`, waiting `wait` seconds for a
    /// socket not there yet.
    private func verify(_ socketPath: String, shared: Bool = false, prelude: String = "", wait: TimeInterval = 0.5) throws -> RemoteSocketCheckFailure? {
        let script = RemoteInstaller.verifyRemoteSocketScript(socketPath: socketPath, agentsRunAsOtherUsers: shared, waitForSocket: wait)
        let ran = try run(script, prelude: prelude)
        return RemoteInstaller.socketProblem(fromCheck: ran.output, errorOutput: ran.errorOutput, exitCode: ran.exitCode, socketPath: socketPath)
    }

    private func mode(_ path: String) throws -> mode_t {
        try XCTUnwrap(SocketPath.lstat(path), path).st_mode & 0o7777
    }

    // MARK: - Before the tunnel: the folder

    /// The folder is made for the SSH user alone, per user (#193), and the
    /// socket's path is in it.
    func testTheFolderIsMadeTheSSHUsersAlone() throws {
        XCTAssertEqual(try prepare(), .success(folder + "/island.sock"))
        let info = try XCTUnwrap(SocketPath.lstat(folder))
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o7777, 0o700)
        // Found again on the next connect.
        XCTAssertEqual(try prepare(), .success(folder + "/island.sock"))
    }

    /// Where agents run as other users, they may pass through the folder to
    /// the socket — by name, and nothing else; turned off, the folder is
    /// the SSH user's alone again.
    func testOtherUsersAgentsMayOnlyPassThroughTheFolder() throws {
        XCTAssertEqual(try prepare(shared: true), .success(folder + "/island.sock"))
        XCTAssertEqual(try mode(folder), 0o711)
        XCTAssertEqual(try prepare(shared: false), .success(folder + "/island.sock"))
        XCTAssertEqual(try mode(folder), 0o700)
    }

    func testAFolderOpenToOthersIsNarrowed() throws {
        XCTAssertEqual(mkdir(folder, 0o700), 0)
        chmod(folder, 0o777)
        XCTAssertEqual(try prepare(), .success(folder + "/island.sock"))
        XCTAssertEqual(try mode(folder), 0o700)
    }

    /// Whatever else sits where the folder goes is refused, and left as it
    /// is: a symlink (even to a folder of the user's), a file.
    func testASymlinkOrAFileWhereTheFolderGoesIsRefused() throws {
        let elsewhere = base + "/elsewhere"
        XCTAssertEqual(mkdir(elsewhere, 0o755), 0)
        XCTAssertEqual(symlink(elsewhere, folder), 0)
        guard case .failure(.folderUnsafe(let path, _)) = try prepare() else {
            return XCTFail("a symlink was taken for the folder")
        }
        XCTAssertEqual(path, folder)
        XCTAssertEqual(try mode(elsewhere), 0o755, "changed through a symlink")
        unlink(folder)

        XCTAssertTrue(FileManager.default.createFile(atPath: folder, contents: Data()))
        guard case .failure(.folderUnsafe) = try prepare() else {
            return XCTFail("a file was taken for the folder")
        }
    }

    /// A folder the SSH user does not own — another user made it first — is
    /// refused: they could put anything in it.
    func testAnotherUsersFolderIsRefused() throws {
        // Run as a uid no account has, beneath /tmp itself (only a base root
        // or the user owns will do), the folder this user made first is
        // another user's.
        let fakeUID = Int.random(in: 3_000_000_000..<3_100_000_000)
        let theirs = RemoteInstaller.remoteSocketFolder(forUID: String(fakeUID))
        XCTAssertEqual(mkdir(theirs, 0o755), 0, theirs)
        defer { rmdir(theirs) }
        let script = RemoteInstaller.prepareRemoteSocketFolderScript(agentsRunAsOtherUsers: false)
        let ran = try run(script, asUID: fakeUID)
        let result = RemoteInstaller.preparedSocketPath(fromProbe: ran.output, errorOutput: ran.errorOutput, exitCode: ran.exitCode)
        XCTAssertEqual(result, .failure(.folderUnsafe(path: theirs, detail: "it belongs to uid \(getuid())")))
        XCTAssertEqual(try mode(theirs), 0o755, "another user's folder was changed")
    }

    /// The folder may only go where other users cannot move it away: a
    /// world-writable base without the sticky bit is refused; /tmp's is fine.
    func testABaseOthersMayMoveFoldersOutOfIsRefused() throws {
        chmod(base, 0o777)
        guard case .failure(.folderUnsafe(_, let detail)) = try prepare() else {
            return XCTFail("a base without the sticky bit was used")
        }
        XCTAssertTrue(detail.contains("move"), detail)
        XCTAssertNil(SocketPath.lstat(folder), "a folder was made there anyway")

        chmod(base, 0o1777)
        XCTAssertEqual(try prepare(), .success(folder + "/island.sock"))
    }

    /// The check runs in whatever login shell the SSH user has: the command
    /// carries nothing any of them reads.
    func testTheCheckRunsTheSameInEveryLoginShell() throws {
        let script = RemoteInstaller.prepareRemoteSocketFolderScript(agentsRunAsOtherUsers: false, base: base)
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let ran = try run(script, shell: shell)
            XCTAssertEqual(
                RemoteInstaller.preparedSocketPath(fromProbe: ran.output, errorOutput: ran.errorOutput, exitCode: ran.exitCode, base: base),
                .success(folder + "/island.sock"),
                "\(shell): \(ran.errorOutput)"
            )
        }
    }

    /// What a login shell prints before the answer is skipped; no answer at
    /// all is ssh's failure, in its own words; an answer that names another
    /// folder than the user's is not taken.
    func testTheAnswerIsReadFromItsOwnLine() {
        let line = #"CODEISLAND-SOCKET-FOLDER {"uid": 1000, "folder": "/tmp/codeisland-1000", "problem": null}"#
        XCTAssertEqual(
            RemoteInstaller.preparedSocketPath(fromProbe: "Welcome to devbox\n" + line + "\n", errorOutput: "", exitCode: 0),
            .success("/tmp/codeisland-1000/island.sock")
        )
        XCTAssertEqual(
            RemoteInstaller.preparedSocketPath(fromProbe: "", errorOutput: "ssh: connect to host devbox port 22: Connection refused\n", exitCode: 255),
            .failure(.unreachable("ssh: connect to host devbox port 22: Connection refused"))
        )
        XCTAssertEqual(
            RemoteInstaller.preparedSocketPath(fromProbe: "", errorOutput: "", exitCode: 255),
            .failure(.unreachable("ssh exited (255)"))
        )
        let elsewhere = #"CODEISLAND-SOCKET-FOLDER {"uid": 1000, "folder": "/home/x", "problem": null}"#
        guard case .failure(.unreachable) = RemoteInstaller.preparedSocketPath(fromProbe: elsewhere, errorOutput: "", exitCode: 0) else {
            return XCTFail("a folder other than the user's own was taken")
        }
    }

    /// The SSH user's uid is read back from the socket's path: the plugin is
    /// told who owns the socket where agents run as other users.
    func testTheSSHUsersUIDIsReadFromTheSocketsPath() {
        XCTAssertEqual(RemoteInstaller.remoteSocketPath(forUID: "1000"), "/tmp/codeisland-1000/island.sock")
        XCTAssertEqual(RemoteInstaller.loginUID(inRemoteSocketPath: RemoteInstaller.remoteSocketPath(forUID: "1000")), "1000")
        for path in ["/tmp/codeisland.sock", "/tmp/codeisland-1000.sock", "/tmp/codeisland-/island.sock",
                     "/tmp/codeisland-10a0/island.sock", "/var/codeisland-1000/island.sock"] {
            XCTAssertNil(RemoteInstaller.loginUID(inRemoteSocketPath: path), path)
        }
    }

    // MARK: - Once the tunnel is up: the socket

    /// The tunnel counts as up a moment after ssh starts, before sshd has
    /// made its forward: a socket that appears while the check waits is
    /// vouched for, not taken for missing.
    func testASocketTheForwardMakesAMomentLaterIsWaitedFor() throws {
        guard case .success(let path) = try prepare() else { return XCTFail("no folder") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) {
            try? leaveSocket(at: path)
        }
        XCTAssertNil(try verify(path, wait: 10))
        XCTAssertNotNil(SocketPath.lstat(path))
    }

    /// The socket sshd made in the folder is the SSH user's: vouched for,
    /// its mode left as it is.
    func testTheSocketTheTunnelMadeIsVouchedFor() throws {
        guard case .success(let path) = try prepare() else { return XCTFail("no folder") }
        try leaveSocket(at: path)
        chmod(path, 0o600)
        XCTAssertNil(try verify(path))
        XCTAssertEqual(try mode(path), 0o600)
    }

    /// Where agents run as other users, the socket gets the mode they need.
    func testOtherUsersAgentsGetASocketTheyCanUse() throws {
        guard case .success(let path) = try prepare(shared: true) else { return XCTFail("no folder") }
        try leaveSocket(at: path)
        chmod(path, 0o600)  // as sshd's own mask leaves it
        XCTAssertNil(try verify(path, shared: true))
        XCTAssertEqual(try mode(path), 0o666)
    }

    /// A host whose Python cannot chmod without following a symlink — Linux
    /// before glibc 2.32 raises ValueError with dir_fd, NotImplementedError
    /// without — still gives the socket its mode, another way.
    func testASocketGetsItsModeWhereChmodMustFollowSymlinks() throws {
        guard case .success(let path) = try prepare(shared: true) else { return XCTFail("no folder") }
        try leaveSocket(at: path)
        for refusal in ["ValueError(\"chmod: cannot use dir_fd and follow_symlinks together\")",
                        "NotImplementedError(\"chmod: follow_symlinks unavailable on this platform\")"] {
            chmod(path, 0o600)
            let prelude = """
                import os
                _chmod = os.chmod
                def _no_nofollow(path, mode, *, dir_fd=None, follow_symlinks=True):
                    if not follow_symlinks:
                        raise \(refusal)
                    return _chmod(path, mode, dir_fd=dir_fd)
                os.chmod = _no_nofollow

                """
            XCTAssertNil(try verify(path, shared: true, prelude: prelude), refusal)
            XCTAssertEqual(try mode(path), 0o666, refusal)
        }
    }

    /// Nothing there, or something other than a socket — a symlink, even to
    /// a socket of the user's — is not vouched for, and nothing is changed
    /// through a symlink.
    func testOnlyASocketInTheFolderIsVouchedFor() throws {
        guard case .success(let path) = try prepare(shared: true) else { return XCTFail("no folder") }
        guard case .socketUnverified(path, let missing)? = try verify(path, shared: true) else {
            return XCTFail("a missing socket was vouched for")
        }
        XCTAssertTrue(missing.contains("No such file"), missing)

        let target = base + "/target.sock"
        try leaveSocket(at: target)
        chmod(target, 0o600)
        XCTAssertEqual(symlink(target, path), 0)
        XCTAssertEqual(try verify(path, shared: true), .socketUnverified(path: path, detail: "not a socket"))
        XCTAssertEqual(try mode(target), 0o600, "changed through a symlink")
    }

    /// A folder that is no longer the SSH user's alone fails the check.
    func testAFolderOpenedUpSinceFailsTheCheck() throws {
        guard case .success(let path) = try prepare() else { return XCTFail("no folder") }
        try leaveSocket(at: path)
        chmod(folder, 0o755)
        guard case .socketUnverified(path, let detail)? = try verify(path) else {
            return XCTFail("a folder others may read was vouched for")
        }
        XCTAssertTrue(detail.contains("mode 755"), detail)
    }
}
