import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The hook socket's default path is a predictable name in /tmp, which
/// another user can take first: a socket of theirs would be sent every hook's
/// payload and could answer a permission request. So every hook sends only to
/// a socket this user owns (and the island says so when the path is taken:
/// HookSocketHealthTests). The real bridge, hook script and remote hook run
/// here against stand-in sockets, never the user's live one.
@MainActor
final class HookSocketOwnershipTests: XCTestCase {
    private var scratch: String!

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        scratch = "/tmp/ci-sown-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    /// A symlink to `target`: connect() follows it, lstat does not.
    private func link(to target: String) throws -> String {
        let path = scratch + "/link.sock"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        return path
    }

    /// Lets a stand-in island that nothing reached go: its accept() returns,
    /// so it closes and removes its socket instead of waiting forever. Read
    /// to its close: it answers in this process, and an answer to a closed
    /// peer would SIGPIPE it.
    private func release(_ server: OneShotUnixServer) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(server.path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }
        shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 256)
        while read(fd, &buffer, buffer.count) > 0 {}
        _ = server.waitUntilServed(timeout: 5)
    }

    // MARK: - The bridge

    private func bridgeBinary() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("codeisland-bridge")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("codeisland-bridge not built next to the test bundle")
        }
        return url
    }

    /// Runs the real bridge on a prompt event, with its socket at `socketPath`;
    /// returns its exit status, what it printed and what it logged.
    private func runBridge(socketPath: String) throws -> (status: Int32, stdout: String, log: String) {
        let log = scratch + "/bridge.log"
        let process = Process()
        process.executableURL = try bridgeBinary()
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CODEISLAND_SOCKET_PATH": socketPath,
            "CODEISLAND_BRIDGE_LOG": log,
            // So a bridge that read the event would log its prompt.
            "CODEISLAND_DEBUG": "1",
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"sown-1","cwd":"/tmp","prompt":"SECRET-PROMPT"}"#
        // The bridge may be gone before it reads: a broken pipe is fine.
        try? stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let logged = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), logged)
    }

    func testBridgeSendsToASocketThisUserOwns() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data("{}".utf8)))
        let run = try runBridge(socketPath: server.path)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(server.waitUntilServed(timeout: 5))
        XCTAssertTrue(String(decoding: server.received, as: UTF8.self).contains("SECRET-PROMPT"))
    }

    func testBridgeSendsNothingThroughASymlink() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data("{}".utf8)))
        let run = try runBridge(socketPath: try link(to: server.path))

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertFalse(server.waitUntilServed(timeout: 1), "the bridge connected through a symlink")
        release(server)
        XCTAssertFalse(run.log.contains("SECRET-PROMPT"), "the bridge read the event before checking the socket")
    }

    /// A real socket another user owns (syslogd's, root's). Were the check
    /// gone, the bridge would read and log the event before its connect
    /// failed; it stops before reading anything.
    func testBridgeSendsNothingToAnotherUsersSocket() throws {
        let path = "/var/run/syslog"
        guard case .otherUser = SocketPath.holder(of: path) else {
            throw XCTSkip("no socket of another user's at \(path)")
        }
        let run = try runBridge(socketPath: path)

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.log, "", "the bridge went past the ownership check")
    }

    // MARK: - The hook script's fallback (no bridge installed)

    /// Runs the hook script with no bridge in HOME, so its nc fallback sends
    /// the event, to `socketPath` instead of the user's live socket.
    private func runHookScriptFallback(socketPath: String) throws {
        let live = #"SOCK="/tmp/codeisland-$(id -u).sock""#
        let script = ConfigInstaller.hookScript
        let redirected = script.replacingOccurrences(of: live, with: "SOCK=\"\(socketPath)\"")
        guard redirected != script, !redirected.contains("/tmp/codeisland-$(id -u)") else {
            return XCTFail("the hook script no longer names its socket as \(live)")
        }
        let scriptPath = scratch + "/codeisland-hook.sh"
        try Data(redirected.utf8).write(to: URL(fileURLWithPath: scriptPath))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? stdin.fileHandleForWriting.write(contentsOf: Data(#"{"hook_event_name":"Stop","session_id":"sown-2"}"#.utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testHookScriptFallbackSendsToASocketThisUserOwns() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data()))
        try runHookScriptFallback(socketPath: server.path)

        XCTAssertTrue(server.waitUntilServed(timeout: 5))
        XCTAssertTrue(String(decoding: server.received, as: UTF8.self).contains("sown-2"))
    }

    func testHookScriptFallbackSendsNothingThroughASymlink() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data()))
        try runHookScriptFallback(socketPath: try link(to: server.path))

        XCTAssertFalse(server.waitUntilServed(timeout: 1), "the fallback connected through a symlink")
        release(server)
    }

    // MARK: - The remote hook

    /// Runs the shipped remote hook's `main()` against a stand-in island at a
    /// path of the driver's; `mode` is how the hook finds it: "direct", through
    /// a "link", "foreign" (another owner, by its lstat and by the kernel's
    /// word on who listens), or "impostor" (a file of its own user's, with
    /// another user listening behind it). Returns what the island received,
    /// nil for nothing.
    private func runRemoteHook(_ mode: String, socketOwnerUID: String? = nil) throws -> String? {
        // The stand-in island of an earlier run in this test left its socket.
        unlink(scratch + "/island.sock")
        unlink(scratch + "/link.sock")
        let hookURL = URL(fileURLWithPath: scratch + "/codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)
        let driver = """
        import importlib.util, io, json, os, socket, sys, threading
        hook_path, scratch, mode = sys.argv[1], sys.argv[2], sys.argv[3]
        island = os.path.join(scratch, "island.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(island)
        server.listen(1)
        server.settimeout(1.5)
        received = {}
        def serve():
            try:
                conn, _ = server.accept()
            except OSError:
                return
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            received["payload"] = data.decode("utf-8")
            conn.close()
        thread = threading.Thread(target=serve)
        thread.start()
        path = island
        if mode == "link":
            path = os.path.join(scratch, "link.sock")
            os.symlink(island, path)
        os.environ["CODEISLAND_SOCKET_PATH"] = path
        spec = importlib.util.spec_from_file_location("hook", hook_path)
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        if mode == "foreign":
            real_lstat = os.lstat
            def foreign_lstat(target, *args, **kwargs):
                info = real_lstat(target, *args, **kwargs)
                return os.stat_result((info.st_mode, info.st_ino, info.st_dev, info.st_nlink,
                                       info.st_uid + 1, info.st_gid, info.st_size,
                                       int(info.st_atime), int(info.st_mtime), int(info.st_ctime)))
            hook.os.lstat = foreign_lstat
        if mode in ("foreign", "impostor"):
            real_peer_uid = hook._peer_uid
            hook._peer_uid = lambda sock: real_peer_uid(sock) + 1
        hook._get_tty = lambda: "/dev/pts/7"
        sys.stdin = io.TextIOWrapper(io.BytesIO(b'{"hook_event_name":"Stop","session_id":"sown-3"}'), encoding="utf-8")
        printed = io.StringIO()
        real_stdout, sys.stdout = sys.stdout, printed
        try:
            hook.main()
        finally:
            sys.stdout = real_stdout
        thread.join(3)
        print(json.dumps({"received": received.get("payload")}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, scratch, mode]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch
        environment["CODEISLAND_SOURCE"] = "claude"
        environment["CODEISLAND_REMOTE_HOST_ID"] = "host-1"
        environment["CODEISLAND_REMOTE_HOST_NAME"] = "Build Box"
        environment["CODEISLAND_SOCKET_OWNER_UID"] = socketOwnerUID
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "hook driver failed: \(err)")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        return result["received"] as? String
    }

    func testRemoteHookSendsToASocketThisUserOwns() throws {
        XCTAssertTrue(try XCTUnwrap(runRemoteHook("direct")).contains("sown-3"))
    }

    func testRemoteHookSendsNothingThroughASymlink() throws {
        XCTAssertNil(try runRemoteHook("link"))
    }

    func testRemoteHookSendsNothingToAnotherUsersSocket() throws {
        XCTAssertNil(try runRemoteHook("foreign"))
    }

    /// A host whose agents run as other users: each hook is told the SSH user
    /// owns the island's socket (sshd made it as that user), and a hook run as
    /// another user sends to it. "foreign" is a socket uid + 1 owns.
    func testRemoteHookSendsToTheSocketOwnerItIsTold() throws {
        let sshUser = String(getuid() + 1)
        XCTAssertTrue(try XCTUnwrap(runRemoteHook("foreign", socketOwnerUID: sshUser)).contains("sown-3"))
    }

    /// And to no other socket: not its own user's, not through a symlink.
    func testRemoteHookSendsNothingToASocketTheNamedOwnerDoesNotOwn() throws {
        XCTAssertNil(try runRemoteHook("direct", socketOwnerUID: String(getuid() + 1)))
        XCTAssertNil(try runRemoteHook("link", socketOwnerUID: String(getuid())))
    }

    /// A malformed owner names nobody: the hook's own user it is.
    func testRemoteHookTakesAMalformedOwnerForItsOwnUser() throws {
        XCTAssertTrue(try XCTUnwrap(runRemoteHook("direct", socketOwnerUID: "1x")).contains("sown-3"))
        XCTAssertNil(try runRemoteHook("foreign", socketOwnerUID: "1x"))
    }

    /// The file says the socket is the island's user's, but the kernel says
    /// another user listens behind it: the hook, which has to connect to ask,
    /// sends nothing.
    func testRemoteHookSendsNothingWhenAnotherUserListensBehindItsSocket() throws {
        XCTAssertEqual(try runRemoteHook("impostor") ?? "", "", "the payload reached a listener of another user's")
    }

    /// What an agent started before its host's hooks were reinstalled sees,
    /// running the command an older install wrote, which names
    /// /tmp/codeisland-<uid>.sock. At each place: nothing, the socket a
    /// finished tunnel left behind (sshd never removes it), an island that
    /// answers, or a listener that takes the request and never answers. Runs
    /// the shipped hook's `main()`; returns which listener got the event,
    /// what the hook printed, and how long `main()` took.
    private func runOlderInstallsCommand(
        event: String,
        atFolder: String,
        atLegacy: String
    ) throws -> (received: [String: Bool], printed: String, seconds: Double) {
        let hookURL = URL(fileURLWithPath: scratch + "/codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)
        // A uid's number no account has: only the path's digits matter.
        let number = String(Int.random(in: 3_000_000_000..<3_100_000_000))
        let driver = """
        import importlib.util, io, json, os, socket, sys, threading, time
        hook_path, number, event, at_folder, at_legacy = sys.argv[1:6]
        legacy = "/tmp/codeisland-%s.sock" % number
        folder = "/tmp/codeisland-%s" % number
        os.mkdir(folder, 0o700)
        places = {"folder": os.path.join(folder, "island.sock"), "legacy": legacy}
        if event == "PermissionRequest":
            answer = b'{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        else:
            answer = b"{}"
        listeners = {}
        stale = []
        for key, kind in (("folder", at_folder), ("legacy", at_legacy)):
            if kind in ("island", "silent"):
                server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                server.bind(places[key])
                server.listen(1)
                server.settimeout(1.5)
                listeners[key] = (server, kind)
            elif kind == "stale":
                # A socket file nobody listens on: what a finished tunnel leaves.
                leftover = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                leftover.bind(places[key])
                leftover.close()
                stale.append(places[key])
        received = {}
        held = []
        def serve(key, server, kind):
            try:
                conn, _ = server.accept()
            except OSError:
                return
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            received[key] = b"sown-legacy" in data
            if kind == "silent":
                # An orphaned tunnel, an sshd whose client is gone: it keeps
                # the request and never answers.
                held.append(conn)
                return
            try:
                conn.sendall(answer)
            except OSError:
                pass
            conn.close()
        threads = [threading.Thread(target=serve, args=(key, server, kind)) for key, (server, kind) in listeners.items()]
        for thread in threads:
            thread.start()
        try:
            os.environ["CODEISLAND_SOCKET_PATH"] = legacy
            spec = importlib.util.spec_from_file_location("hook", hook_path)
            hook = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(hook)
            hook._get_tty = lambda: "/dev/pts/7"
            # Bounds a request sent where nobody answers; the real wait is a day.
            hook.BLOCKING_TIMEOUT_SECONDS = 5
            stdin = json.dumps({"hook_event_name": event, "session_id": "sown-legacy",
                                "tool_name": "Bash", "tool_input": {"command": "make"}})
            sys.stdin = io.TextIOWrapper(io.BytesIO(stdin.encode("utf-8")), encoding="utf-8")
            printed = io.StringIO()
            real_stdout, sys.stdout = sys.stdout, printed
            started = time.monotonic()
            try:
                hook.main()
            finally:
                sys.stdout = real_stdout
            seconds = time.monotonic() - started
            for thread in threads:
                thread.join(3)
        finally:
            for conn in held:
                conn.close()
            for server, _ in listeners.values():
                server.close()
            for path in [places[key] for key in listeners] + stale:
                os.unlink(path)
            os.rmdir(folder)
        print(json.dumps({"received": received, "printed": printed.getvalue().strip(), "seconds": seconds}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, number, event, atFolder, atLegacy]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch
        environment["CODEISLAND_SOURCE"] = "claude"
        environment.removeValue(forKey: "CODEISLAND_SOCKET_OWNER_UID")
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "hook driver failed: \(err)")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        return (
            try XCTUnwrap(result["received"] as? [String: Bool]),
            result["printed"] as? String ?? "",
            result["seconds"] as? Double ?? .infinity
        )
    }

    /// The script on the host is the one the newest island installed, and
    /// only such an island listens in the folder: its socket comes first.
    /// The old path is used only while the folder has no island, for an
    /// older one still forwarding there; with both up (a host connected to
    /// two Macs of different versions), the newer island gets the event.
    func testAHookAnOlderInstallWroteFindsTheSocketInItsFolder() throws {
        let cases: [(atFolder: String, atLegacy: String, expected: [String: Bool])] = [
            ("island", "nothing", ["folder": true]),
            ("island", "stale", ["folder": true]),
            ("island", "island", ["folder": true]),
            ("nothing", "island", ["legacy": true]),
            ("stale", "island", ["legacy": true]),
        ]
        for (atFolder, atLegacy, expected) in cases {
            let run = try runOlderInstallsCommand(event: "Stop", atFolder: atFolder, atLegacy: atLegacy)
            XCTAssertEqual(run.received, expected, "with \(atFolder) in the folder and \(atLegacy) at the old path")
        }
    }

    /// Something still listens at the old path that is no island: the tunnel
    /// of an older island whose app crashed or was force-quit (it forwards to
    /// the Mac's main socket, which refuses a remote host's requests now), or
    /// an sshd whose client is gone. Taking the old path first, the hook lost
    /// every event of an agent started before the reinstall to it — a Stop
    /// after its 2 s wait for a reply, a permission request after waiting as
    /// long as the agent lets it. The island in the folder gets them now, at
    /// once.
    func testAListenerLeftAtTheOldPathDoesNotTakeTheIslandsEvents() throws {
        let stop = try runOlderInstallsCommand(event: "Stop", atFolder: "island", atLegacy: "silent")
        XCTAssertEqual(stop.received, ["folder": true])
        XCTAssertLessThan(stop.seconds, 1.5, "the Stop waited for a reply that never came")

        let request = try runOlderInstallsCommand(event: "PermissionRequest", atFolder: "island", atLegacy: "silent")
        XCTAssertEqual(request.received, ["folder": true])
        XCTAssertLessThan(request.seconds, 1.5, "the permission request hung on the old path")
        XCTAssertTrue(
            request.printed.contains(#""behavior":"allow""#),
            "the island's answer never reached the agent: \(request.printed)"
        )
    }

    /// The hook sends text as it is, in UTF-8: `\uXXXX` escapes would double
    /// a CJK text against the island's limit on a remote host's request. A
    /// lone surrogate, which UTF-8 cannot carry, is escaped instead.
    func testTheHookSendsTextAsItIs() throws {
        let hookURL = URL(fileURLWithPath: scratch + "/codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)
        let driver = """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        text = hook._wire({"content": "\\u5199\\u6587\\u4ef6"})
        lone = hook._wire({"content": "a\\ud800b"})
        print(json.dumps({
            "raw": "\\u5199".encode("utf-8") in text and b"\\\\u" not in text,
            "same": json.loads(text.decode("utf-8")) == {"content": "\\u5199\\u6587\\u4ef6"},
            "lone": b"\\\\ud800" in lone,
        }))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, err)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Bool])
        XCTAssertEqual(result, ["raw": true, "same": true, "lone": true])
    }

    /// Each platform's answer is read where its uid is: Linux's struct ucred
    /// (pid, uid, gid), OpenBSD's struct sockpeercred (uid, gid, pid), the
    /// struct xucred of macOS and FreeBSD (version, uid, …). A platform with
    /// no way to ask says nothing; one where asking fails names nobody.
    func testTheHookReadsEachPlatformsPeerCredentials() throws {
        let hookURL = URL(fileURLWithPath: scratch + "/codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)
        let driver = """
        import importlib.util, socket, struct, sys
        spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        class Answers:
            def __init__(self, data):
                self.data = data
            def getsockopt(self, level, option, size):
                if self.data is None:
                    raise OSError(95, "Operation not supported")
                return self.data
        socket.SO_PEERCRED = getattr(socket, "SO_PEERCRED", 17)
        found = []
        for platform, data in [
            ("linux", struct.pack("iII", 4242, 1000, 1001)),
            ("openbsd7", struct.pack("IIi", 1000, 1001, 4242)),
            ("darwin", struct.pack("=IIh", 0, 1000, 1) + bytes(66)),
            ("freebsd14", struct.pack("=IIh", 0, 1000, 1) + bytes(74)),
            ("sunos5", b""),
            ("linux", None),
        ]:
            sys.platform = platform
            found.append(hook._peer_uid(Answers(data)))
        print(found)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "[1000, 1000, 1000, 1000, None, -1]")
    }

    /// The hook asks the kernel who listens (LOCAL_PEERCRED here, as on
    /// macOS hosts; SO_PEERCRED on Linux): the island's stand-in, this user.
    func testRemoteHookAsksTheKernelWhoListens() throws {
        let hookURL = URL(fileURLWithPath: scratch + "/codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)
        let driver = """
        import importlib.util, os, socket, sys
        spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        path = os.path.join(sys.argv[2], "peer.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(path)
        print(hook._peer_uid(client), hook._peer_is_island(client))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, scratch]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "\(getuid()) True")
    }
}
