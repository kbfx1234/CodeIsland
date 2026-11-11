import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// HookServer's socket against real clients on a throwaway path: what a
/// hook writes reaches the island however early the hook closes and however
/// busy the main thread is, a held request waits for its answer, and one
/// whose hook is gone is dropped. The socket is a remote host's, as the
/// remote hook reaches it (``RemoteHookSockets``): its hooks are the ones
/// that close early, over a slow link.
@MainActor
final class HookServerTransportTests: XCTestCase {
    private var socketPath: String!
    private var appState: AppState!
    private var server: HookServer!

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        socketPath = "/tmp/ci-ht-\(UUID().uuidString.prefix(8)).sock"
        appState = AppState()
        server = HookServer(appState: appState, socketPath: socketPath, origin: Self.buildBox, hostCwdFilter: { _ in nil })
        XCTAssertTrue(server.start(), "HookServer did not listen on \(socketPath!)")
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        appState = nil
        unlink(socketPath)
    }

    /// The remote host whose socket the tests' hooks reach.
    private static let buildBox = HookOrigin.remoteHost(id: "host-1", name: "Build Box")

    /// A payload a remote hook installed before `_edge` sends: its own
    /// interpretation, filed under its host.
    private func remotePayload(_ event: String, session: String, extra: String = "") -> String {
        #"{"hook_event_name":"\#(event)","session_id":"\#(session)","cwd":"/work/proj","_source":"claude","_remote_host_id":"host-1","_remote_host_name":"Build Box"\#(extra)}"#
    }

    /// A PermissionRequest for one tool call, as a remote hook sends it.
    private func permissionPayload(session: String, toolUseId: String, command: String = "make") -> String {
        remotePayload(
            "PermissionRequest",
            session: session,
            extra: #","tool_name":"Bash","tool_use_id":"\#(toolUseId)","tool_input":{"command":"\#(command)"}"#
        )
    }

    /// Runs the main run loop until `condition` holds; false (and a failure) after `timeout`.
    @discardableResult
    private func pump(
        until condition: () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message, file: file, line: line)
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    private func pump(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Replaces the server with one on a socket of its own, checking held
    /// requests' hooks every `heldRequestCheckInterval`, with a remote
    /// host's limits as `adjust` changes them.
    private func restartServer(
        heldRequestCheckInterval: TimeInterval = 300,
        _ adjust: (inout HookSocketLimits) -> Void = { _ in }
    ) {
        server.stop()
        unlink(socketPath)
        socketPath = "/tmp/ci-ht-\(UUID().uuidString.prefix(8)).sock"
        var limits = HookSocketLimits.remoteHost
        adjust(&limits)
        server = HookServer(
            appState: appState,
            socketPath: socketPath,
            origin: Self.buildBox,
            hostCwdFilter: { _ in nil },
            heldRequestCheckInterval: heldRequestCheckInterval,
            limits: limits
        )
        XCTAssertTrue(server.start(), "HookServer did not listen on \(socketPath!)")
    }

    /// A hook that does not wait for an answer writes its event and closes at
    /// once — while the island's main thread is busy (rendering, a
    /// synchronous read). NWListener dropped such a connection whenever its
    /// peer had closed before it was set up, and the event was lost.
    func testEventsFromHooksThatCloseAtOnceSurviveABusyMainThread() throws {
        let path = socketPath!
        let count = 10
        for index in 0..<count {
            let payload = remotePayload("UserPromptSubmit", session: "early-\(index)", extra: #","prompt":"p\#(index)""#)
            let sent = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                RawHook.sendAndClose(payload, to: path)
                sent.signal()
            }
            // The main thread is busy while the hook connects, writes and
            // closes, and for a while after.
            XCTAssertEqual(sent.wait(timeout: .now() + 5), .success)
            usleep(150_000)
        }
        let delivered = { self.appState.sessions.keys.filter { $0.hasPrefix("remote:host-1:early-") }.count }
        pump(until: { delivered() == count }, "\(delivered()) of \(count) events reached the island")
    }

    /// The shipped remote hook, with the island's main thread busy after
    /// each hook starts.
    func testFireAndForgetRemoteEventsSurviveABusyMainThread() throws {
        let sandbox = URL(fileURLWithPath: "/tmp/ci-ht-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("home"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let hookURL = sandbox.appendingPathComponent("codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)

        for index in 0..<5 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [hookURL.path]
            process.currentDirectoryURL = sandbox
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": sandbox.appendingPathComponent("home").path,
                "CODEISLAND_SOCKET_PATH": socketPath,
                "CODEISLAND_SOURCE": "opencode",
                "CODEISLAND_REMOTE_HOST_ID": "host-1",
                "CODEISLAND_REMOTE_HOST_NAME": "Build Box",
            ]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // The remote OpenCode plugin's payload shape (it names its tty).
            input.fileHandleForWriting.write(Data(#"{"session_id":"busy-\#(index)","hook_event_name":"UserPromptSubmit","cwd":"/work/proj","prompt":"p\#(index)","_tty":"/dev/pts/7"}"#.utf8))
            try input.fileHandleForWriting.close()
            usleep(300_000)  // the island's main thread is busy
            pump(until: { !process.isRunning }, timeout: 10, "the hook did not exit")
        }
        let delivered = { (0..<5).filter { self.appState.sessions["remote:host-1:busy-\($0)"] != nil }.count }
        pump(until: { delivered() == 5 }, "\(delivered()) of 5 remote events reached the island")
    }

    /// A blocking request: the hook half-closes once it has written, which is
    /// not a disconnect — the card stays, and the answer reaches the hook.
    func testAHeldRequestWaitsForItsAnswer() throws {
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(remotePayload("PermissionRequest", session: "held-1", extra: #","tool_name":"Bash","tool_input":{"command":"make"}"#))
        let answer = hook.readAnswerInBackground()

        pump(until: { self.appState.pendingPermission != nil }, "no card for the request")
        pump(for: 0.5)
        XCTAssertNotNil(appState.pendingPermission, "the hook's half-close was taken for a disconnect")

        appState.approvePermission()
        pump(until: { answer.value != nil }, "the answer did not reach the hook")
        let text = String(decoding: answer.value ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""behavior":"allow""#), text)
        hook.close()
    }

    /// A held request stays answerable for as long as its hook waits — the
    /// bridge waits up to a day for someone who stepped away (#306). The
    /// safety net that checks held requests now and then never cuts off a
    /// hook that is still there.
    func testAHeldRequestOutlivesTheSafetyNet() throws {
        restartServer(heldRequestCheckInterval: 0.1)
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(permissionPayload(session: "away", toolUseId: "tu-away"))
        let answer = hook.readAnswerInBackground()

        pump(until: { self.appState.pendingPermission != nil }, "no card for the request")
        pump(for: 1)  // ten rounds of the safety net
        XCTAssertNotNil(appState.pendingPermission, "the safety net dropped a request whose hook still waits")
        XCTAssertNil(answer.value, "the safety net cut off a waiting hook")

        appState.approvePermission()
        pump(until: { answer.value != nil }, "the answer did not reach the hook")
        XCTAssertTrue(String(decoding: answer.value ?? Data(), as: UTF8.self).contains(#""behavior":"allow""#))
        hook.close()
    }

    /// A hook that never finishes its request (no EOF, nothing more sent)
    /// is let go after the read's idle timeout instead of holding its
    /// socket forever.
    func testAHookThatNeverFinishesItsRequestIsLetGo() throws {
        restartServer { $0.readIdleTimeout = 0.3 }
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.writeWithoutFinishing(#"{"hook_event_name":"Stop","#)

        let answer = hook.readAnswerInBackground(timeout: 3)
        pump(until: { answer.value != nil }, timeout: 6, "the hook's read never ended")
        XCTAssertFalse(answer.timedOut, "a hook that never finished its request was held on to")
        XCTAssertEqual(answer.value, Data())
        hook.close()
    }

    /// The read's idle timeout ends with the request: the wait for a held
    /// request's answer that follows is not bound by it.
    func testAHeldRequestIsNotBoundByTheReadTimeout() throws {
        restartServer { $0.readIdleTimeout = 0.2 }
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(permissionPayload(session: "slow-user", toolUseId: "tu-slow"))
        let answer = hook.readAnswerInBackground()

        pump(until: { self.appState.pendingPermission != nil }, "no card for the request")
        pump(for: 1)
        XCTAssertNotNil(appState.pendingPermission, "the read's timeout cut off a held request")
        XCTAssertNil(answer.value, "the read's timeout cut off a waiting hook")

        appState.approvePermission()
        pump(until: { answer.value != nil }, "the answer did not reach the hook")
        XCTAssertTrue(String(decoding: answer.value ?? Data(), as: UTF8.self).contains(#""behavior":"allow""#))
        hook.close()
    }

    /// A blocking request whose hook is gone (killed, or its agent answered
    /// in the terminal) drops its card at once.
    func testAHeldRequestEndsWithItsHook() throws {
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(remotePayload("PermissionRequest", session: "held-2", extra: #","tool_name":"Bash","tool_input":{"command":"make"}"#))

        pump(until: { self.appState.pendingPermission != nil }, "no card for the request")
        hook.close()
        pump(until: { self.appState.pendingPermission == nil }, timeout: 2, "the card outlived its hook")
    }

    /// Two held requests of one session and agent — parallel tool calls —
    /// and one hook goes: its card goes, and only its. The other hook still
    /// waits on the user, and gets the user's answer.
    func testAHookThatGoesTakesOnlyItsOwnRequest() throws {
        let gone = try XCTUnwrap(RawHook.connect(to: socketPath))
        gone.write(permissionPayload(session: "pair", toolUseId: "tu-a"))
        pump(until: { self.appState.permissionQueue.count == 1 }, "no card for the first request")
        let waiting = try XCTUnwrap(RawHook.connect(to: socketPath))
        waiting.write(permissionPayload(session: "pair", toolUseId: "tu-b", command: "make test"))
        let answer = waiting.readAnswerInBackground()
        pump(until: { self.appState.permissionQueue.count == 2 }, "no card for the second request")

        gone.close()
        pump(until: { self.appState.permissionQueue.count != 2 }, timeout: 2, "the card outlived its hook")
        pump(for: 0.3)
        XCTAssertEqual(appState.permissionQueue.map(\.toolUseId), ["tu-b"], "a sibling's card went with the hook")
        XCTAssertNil(answer.value, "the waiting hook was answered without the user: \(String(decoding: answer.value ?? Data(), as: UTF8.self))")

        appState.approvePermission()
        pump(until: { answer.value != nil }, "the answer did not reach the waiting hook")
        XCTAssertTrue(String(decoding: answer.value ?? Data(), as: UTF8.self).contains(#""behavior":"allow""#))
        waiting.close()
    }

    /// The same for two questions of one session.
    func testAQuestionsHookThatGoesTakesOnlyItsOwnQuestion() throws {
        let gone = try XCTUnwrap(RawHook.connect(to: socketPath))
        gone.write(remotePayload("Notification", session: "ask", extra: #","question":"First?""#))
        pump(until: { self.appState.questionQueue.count == 1 }, "no card for the first question")
        let waiting = try XCTUnwrap(RawHook.connect(to: socketPath))
        waiting.write(remotePayload("Notification", session: "ask", extra: #","question":"Second?""#))
        let answer = waiting.readAnswerInBackground()
        pump(until: { self.appState.questionQueue.count == 2 }, "no card for the second question")

        gone.close()
        pump(until: { self.appState.questionQueue.count != 2 }, timeout: 2, "the question outlived its hook")
        pump(for: 0.3)
        XCTAssertEqual(appState.questionQueue.map(\.question.question), ["Second?"], "a sibling's question went with the hook")
        XCTAssertNil(answer.value, "the waiting hook was answered without the user: \(String(decoding: answer.value ?? Data(), as: UTF8.self))")

        waiting.close()
        pump(until: { self.appState.questionQueue.isEmpty }, timeout: 2, "the question outlived its hook")
    }

    /// A replay of a held request (the same tool call, asked again) takes
    /// the first one's place, and the first hook gets its answer. The card
    /// then goes with the replay's hook, not with the first one's.
    func testAReplayedRequestGoesWithTheReplaysHook() throws {
        let first = try XCTUnwrap(RawHook.connect(to: socketPath))
        first.write(permissionPayload(session: "replay", toolUseId: "tu-r"))
        let firstAnswer = first.readAnswerInBackground()
        pump(until: { self.appState.permissionQueue.count == 1 }, "no card for the request")
        let replay = try XCTUnwrap(RawHook.connect(to: socketPath))
        replay.write(permissionPayload(session: "replay", toolUseId: "tu-r"))
        pump(until: { firstAnswer.value != nil }, "the replay did not let the first hook go")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        first.close()
        pump(for: 0.5)
        XCTAssertEqual(appState.permissionQueue.count, 1, "the replay's card went with the first hook")
        replay.close()
        pump(until: { self.appState.permissionQueue.isEmpty }, timeout: 2, "the card outlived the replay's hook")
    }

    /// Short of descriptors, accept() fails — and XNU drops that connection.
    /// The listener backs off rather than spin, and accepts again once
    /// descriptors are back.
    func testTheListenerOutlivesRunningOutOfDescriptors() throws {
        let clients = (0..<3).map { _ in socket(AF_UNIX, SOCK_STREAM, 0) }
        defer { clients.forEach { Darwin.close($0) } }
        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &saved), 0)
        // The lowest free descriptor: a limit there leaves none to open.
        var lowest: Int32 = 0
        while fcntl(lowest, F_GETFD) != -1 { lowest += 1 }
        var limited = saved
        limited.rlim_cur = rlim_t(lowest)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limited), 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8)) }
        for (index, client) in clients.enumerated() {
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(connected, 0, "connect: \(String(cString: strerror(errno)))")
            let payload = remotePayload("UserPromptSubmit", session: "short-\(index)", extra: #","prompt":"p""#)
            _ = payload.withCString { send(client, $0, strlen($0), MSG_NOSIGNAL) }
            shutdown(client, SHUT_WR)
        }
        pump(for: 0.5)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &saved), 0)

        RawHook.sendAndClose(remotePayload("UserPromptSubmit", session: "after", extra: #","prompt":"p""#), to: socketPath)
        pump(until: { self.appState.sessions["remote:host-1:after"] != nil }, "the listener stopped accepting")
    }

    /// A server released while a request is on its way to the main actor
    /// drops the connection; its hook is let go, not left waiting.
    func testAServerReleasedMidRequestLetsItsHookGo() throws {
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(remotePayload("UserPromptSubmit", session: "released", extra: #","prompt":"p""#))
        usleep(300_000)  // the request is read off the main thread; its hop to it waits
        server.stop()
        server = nil

        let answer = hook.readAnswerInBackground(timeout: 3)
        pump(until: { answer.value != nil }, timeout: 6, "the hook's read never ended")
        XCTAssertFalse(answer.timedOut, "the dropped connection was neither answered nor closed")
        hook.close()
    }

    /// Every held request is watched through one kqueue: holding one costs
    /// its socket and nothing more. It cost a kqueue of its own as well, and
    /// launchd's 256 descriptors ran out twice as fast.
    func testHeldRequestsShareOneKqueue() throws {
        let before = try openKqueues()
        var hooks: [RawHook] = []
        for index in 0..<10 {
            let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
            hook.write(permissionPayload(session: "fd-\(index)", toolUseId: "tu-\(index)"))
            hooks.append(hook)
        }
        pump(until: { self.appState.permissionQueue.count == 10 }, "no cards for the requests")
        pump(for: 0.3)  // every watch is set
        XCTAssertLessThanOrEqual(try openKqueues() - before, 1, "a held request costs a kqueue of its own")

        hooks.forEach { $0.close() }
        pump(until: { self.appState.permissionQueue.isEmpty }, timeout: 2, "cards outlived their hooks")
    }

    /// This process's open kqueues.
    private func openKqueues() throws -> Int {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { throw XCTSkip("proc_pidinfo: \(String(cString: strerror(errno)))") }
        var infos = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &infos, size)
        return infos.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_KQUEUE) }
            .count
    }

    /// More than the island reads of one request on this Mac's socket is
    /// not read on, nothing reaches a card, and the answer is nothing: the
    /// island decides nothing it never read, so the agent asks in its own way.
    func testAnOversizedRequestIsLeftToItsAgent() throws {
        let local = try startLocalServer()
        defer { stopLocalServer(local) }
        let hook = try XCTUnwrap(RawHook.connect(to: local.socketPath))
        let answer = hook.writeInBackground(Data(repeating: UInt8(ascii: " "), count: 10_485_761), thenRead: true)
        pump(until: { answer.value != nil }, timeout: 10, "no answer to an oversized request")
        XCTAssertFalse(answer.timedOut, "an oversized request was read on")
        XCTAssertEqual(answer.value, Data(), "an oversized request got an answer")
        XCTAssertNil(appState.pendingPermission)
        hook.close()
    }

    // MARK: - A remote host's share of the island

    /// What one remote host may take, and what this Mac's hooks keep.
    func testARemoteHostGetsABoundedShareAndThisMacKeepsItsOwn() {
        XCTAssertEqual(server.limits, .remoteHost, "a remote host's socket takes a remote host's limits")
        XCTAssertEqual(HookServer(appState: appState, socketPath: "/tmp/ci-unused.sock").limits, .local)
        XCTAssertEqual(HookSocketLimits.local.maxRequestBytes, 10_485_760, "this Mac's requests stay up to 10 MB")
        XCTAssertNil(HookSocketLimits.local.maxConnections)
        XCTAssertNil(HookSocketLimits.local.maxHeldRequests)
        XCTAssertNil(HookSocketLimits.local.maxBufferedBytes)
        XCTAssertNil(HookSocketLimits.local.readDeadline)
        let remote = HookSocketLimits.remoteHost
        XCTAssertEqual(remote.maxRequestBytes, 1_048_576)
        XCTAssertNotNil(remote.maxConnections)
        XCTAssertNotNil(remote.maxHeldRequests)
        XCTAssertNotNil(remote.maxBufferedBytes)
        XCTAssertGreaterThanOrEqual(remote.readDeadline ?? 0, 120, "minutes for a slow SSH link")
        // Many hosts at their caps together stay far from the descriptors
        // every socket shares.
        XCTAssertLessThan((remote.maxConnections ?? .max) * 16, Int(HookSocketListener.wantedDescriptorLimit))
        XCTAssertLessThanOrEqual(remote.maxHeldRequests ?? .max, remote.maxConnections ?? .max)
    }

    /// A remote host's request may be a megabyte, no more: the rest is not
    /// read, nothing reaches a card, and the answer is nothing — a large file
    /// an agent writes there is not refused, its agent asks in its own way.
    func testARemoteHostsRequestOverAMegabyteIsLeftToItsAgent() throws {
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        let answer = hook.writeInBackground(Data(repeating: UInt8(ascii: " "), count: 1_048_577), thenRead: true)
        pump(until: { answer.value != nil }, timeout: 10, "no answer to an oversized request")
        XCTAssertFalse(answer.timedOut, "an oversized request was read on")
        XCTAssertEqual(answer.value, Data(), "an oversized request got an answer")
        XCTAssertNil(appState.pendingPermission)
        hook.close()
    }

    /// This Mac's hooks keep their 10 MB: a request of several megabytes is
    /// handled.
    func testThisMacsHooksStillSendRequestsOfSeveralMegabytes() throws {
        let local = try startLocalServer()
        defer { stopLocalServer(local) }
        let message = String(repeating: "x", count: 3_000_000)
        let payload = #"{"hook_event_name":"Stop","session_id":"big-local","cwd":"/tmp","_source":"claude","last_assistant_message":"\#(message)"}"#
        let hook = try XCTUnwrap(RawHook.connect(to: local.socketPath))
        let answer = hook.writeInBackground(Data(payload.utf8), thenRead: true)
        pump(until: { answer.value != nil }, timeout: 10, "no answer to a large local request")
        XCTAssertEqual(String(decoding: answer.value ?? Data(), as: UTF8.self), "{}", "a local request of 3 MB was refused")
        hook.close()
    }

    /// A remote host may hold so many connections open at once. One more is
    /// closed at once — its hook finds no island — while this Mac's socket
    /// answers as ever; and the host's socket takes connections again once
    /// one of its own closes.
    func testARemoteHostMayHoldSoManyConnectionsAndThisMacStillAnswers() throws {
        restartServer { $0.maxConnections = 3 }
        // Three hooks that never finish their requests hold the host's share.
        let holding = try (0..<3).map { _ -> RawHook in
            let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
            hook.writeWithoutFinishing(#"{"hook_event_name":"Stop","#)
            return hook
        }
        defer { holding.forEach { $0.close() } }
        pump(for: 0.3)
        let turnedAway = try XCTUnwrap(RawHook.connect(to: socketPath))
        let refused = turnedAway.readAnswerInBackground(timeout: 3)
        pump(until: { refused.value != nil }, timeout: 6, "a connection past the host's share was kept")
        XCTAssertFalse(refused.timedOut, "a connection past the host's share was kept waiting")
        XCTAssertEqual(refused.value, Data())
        turnedAway.close()

        let local = try startLocalServer()
        defer { stopLocalServer(local) }
        let localHook = try XCTUnwrap(RawHook.connect(to: local.socketPath))
        let localAnswer = localHook.writeInBackground(
            Data(#"{"hook_event_name":"Stop","session_id":"local-1","cwd":"/tmp","_source":"claude"}"#.utf8),
            thenRead: true
        )
        pump(until: { localAnswer.value != nil }, "this Mac's socket went unanswered")
        XCTAssertEqual(String(decoding: localAnswer.value ?? Data(), as: UTF8.self), "{}")
        localHook.close()

        // One of the host's own goes: its socket takes a connection again,
        // once the island has seen it go.
        holding[0].close()
        var answered: Data?
        let deadline = Date().addingTimeInterval(5)
        while answered != Data("{}".utf8), Date() < deadline {
            let next = try XCTUnwrap(RawHook.connect(to: socketPath))
            let answer = next.writeInBackground(Data(remotePayload("Stop", session: "after").utf8), thenRead: true)
            pump(until: { answer.value != nil }, "no answer once a connection had closed")
            answered = answer.value
            next.close()
            if answered != Data("{}".utf8) { pump(for: 0.1) }
        }
        XCTAssertEqual(String(decoding: answered ?? Data(), as: UTF8.self), "{}", "the socket took no connection again")
    }

    /// A remote host may have so many requests waiting on an answer. One more
    /// is answered at once with nothing — no card; its agent asks in its own
    /// way — and once one is answered the host may hold another.
    func testARemoteHostMayHoldSoManyRequestsForAnAnswer() throws {
        restartServer { $0.maxHeldRequests = 2 }
        let held = try (0..<2).map { index -> (hook: RawHook, answer: RawHook.Box) in
            let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
            hook.write(permissionPayload(session: "held-\(index)", toolUseId: "tu-\(index)"))
            return (hook, hook.readAnswerInBackground())
        }
        defer { held.forEach { $0.hook.close() } }
        pump(until: { self.appState.permissionQueue.count == 2 }, "the host's two requests got no cards")

        let third = try XCTUnwrap(RawHook.connect(to: socketPath))
        third.write(permissionPayload(session: "held-2", toolUseId: "tu-2"))
        let thirdAnswer = third.readAnswerInBackground(timeout: 3)
        pump(until: { thirdAnswer.value != nil }, timeout: 6, "a request past the host's share was held")
        XCTAssertFalse(thirdAnswer.timedOut)
        XCTAssertEqual(thirdAnswer.value, Data(), "a request past the host's share got an answer")
        XCTAssertEqual(appState.permissionQueue.count, 2, "a request past the host's share got a card")
        third.close()

        appState.approvePermission()
        pump(until: { held.contains { $0.answer.value != nil } }, "the approval did not reach its hook")
        let fourth = try XCTUnwrap(RawHook.connect(to: socketPath))
        fourth.write(permissionPayload(session: "held-3", toolUseId: "tu-3"))
        let fourthAnswer = fourth.readAnswerInBackground()
        pump(until: { self.appState.permissionQueue.count == 2 }, "a request within the host's share got no card")
        pump(for: 0.3)
        XCTAssertNil(fourthAnswer.value, "a request within the host's share was not held")
        fourth.close()
    }

    /// A remote host's unfinished requests share a budget of bytes: the
    /// connection that would pass it is dropped at once, the other read on.
    func testARemoteHostsUnfinishedRequestsShareABudget() throws {
        restartServer { $0.maxBufferedBytes = 100 }
        let first = try XCTUnwrap(RawHook.connect(to: socketPath))
        first.writeWithoutFinishing(String(repeating: " ", count: 80))
        let second = try XCTUnwrap(RawHook.connect(to: socketPath))
        second.writeWithoutFinishing(String(repeating: " ", count: 40))
        // Well inside the idle timeout (two minutes): only the budget ends
        // either — whichever the island read last.
        let answers = [first, second].map { $0.readAnswerInBackground(timeout: 3) }
        pump(until: { answers.allSatisfy { $0.value != nil } }, timeout: 6, "no answers")
        let dropped = answers.filter { !$0.timedOut }
        XCTAssertEqual(dropped.count, 1, "not one connection past the host's budget was dropped")
        XCTAssertEqual(dropped.first?.value, Data())
        second.close()
        first.close()
    }

    /// A remote host's request must be complete by the read deadline,
    /// however steadily it trickles in.
    func testARemoteHostsTrickleIsCutOffAtTheReadDeadline() throws {
        restartServer {
            $0.readIdleTimeout = 0.5
            $0.readDeadline = 1
        }
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        let answer = hook.readAnswerInBackground(timeout: 5)
        let trickled = Flag()
        DispatchQueue.global().async {
            for _ in 0..<40 where answer.value == nil {
                hook.writeWithoutFinishing(" ")
                usleep(100_000)  // four seconds in all, never half a second silent
            }
            trickled.set()
        }
        let started = Date()
        pump(until: { answer.value != nil }, timeout: 6, "a trickle held its connection")
        XCTAssertFalse(answer.timedOut, "a trickle held its connection")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "a trickle held its connection past the deadline")
        pump(until: { trickled.isSet }, "the trickle never stopped")
        hook.close()
    }

    /// A server on this Mac's terms, on a socket of its own.
    private func startLocalServer() throws -> HookServer {
        let path = "/tmp/ci-ht-\(UUID().uuidString.prefix(8)).sock"
        let local = HookServer(appState: appState, socketPath: path, hostCwdFilter: { _ in nil })
        XCTAssertTrue(local.start(), "HookServer did not listen on \(path)")
        return local
    }

    private func stopLocalServer(_ local: HookServer) {
        local.stop()
        unlink(local.socketPath)
    }
}

/// One HookConnection on a socket pair, the hook's end in the test's hands.
final class HookConnectionTests: XCTestCase {
    private let queue = DispatchQueue(label: "HookConnectionTests")
    private var hookEnds: [Int32] = []

    override func tearDown() {
        hookEnds.forEach { Darwin.close($0) }
        hookEnds = []
        super.tearDown()
    }

    /// A connection and the hook's end of it.
    private func connectionPair(peerWatch: HookPeerWatch = .shared) throws -> (HookConnection, hook: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair: \(String(cString: strerror(errno)))")
        }
        hookEnds.append(fds[1])
        return (HookConnection(fd: fds[0], queue: queue, peerWatch: peerWatch), fds[1])
    }

    /// Closes the hook's end.
    private func closeHook(_ hook: Int32) {
        Darwin.close(hook)
        hookEnds.removeAll { $0 == hook }
    }

    /// Set once `connection` closes.
    private func closing(_ connection: HookConnection) -> Flag {
        let closed = Flag()
        connection.onClose { closed.set() }
        return closed
    }

    /// Waits until `flag` is set; false after `timeout`.
    private func wait(for flag: Flag, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.isSet {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    /// The safety net's check closes a held connection only once its hook
    /// is gone: a hook that half-closed and waits for its answer stays.
    func testThePeerCheckLeavesAWaitingHookAlone() throws {
        let (connection, hook) = try connectionPair()
        let closed = closing(connection)
        shutdown(hook, SHUT_WR)  // the request is written; the hook waits

        connection.closeIfPeerGone()
        XCTAssertFalse(wait(for: closed, timeout: 0.3), "the check cut off a waiting hook")

        closeHook(hook)
        connection.closeIfPeerGone()
        XCTAssertTrue(wait(for: closed, timeout: 2), "the check missed a hook that is gone")
    }

    /// A connection dropped after its request, without an answer or
    /// cancel(), closes: its hook sees the end of the answer instead of
    /// waiting on a socket nobody holds.
    func testADroppedConnectionLetsItsHookGo() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let hook = fds[1]
        hookEnds.append(hook)
        _ = "{}".withCString { send(hook, $0, 2, MSG_NOSIGNAL) }
        shutdown(hook, SHUT_WR)
        let read = Flag()
        do {
            let connection = HookConnection(fd: fds[0], queue: queue)
            queue.async {
                connection.readRequest(limit: 1_024) { _ in read.set() }
            }
        }
        XCTAssertTrue(wait(for: read, timeout: 2), "the request was not read")

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(hook, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        let got = recv(hook, &byte, 1, 0)
        XCTAssertEqual(got, 0, "the hook still waits: \(got < 0 ? String(cString: strerror(errno)) : "a byte")")
    }

    /// Everything the island writes to `hook`, to its EOF (or 5 s of silence).
    private func readToEOF(_ hook: Int32) -> Data {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(hook, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(hook, &buffer, buffer.count, 0)
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return data
            }
        }
    }

    /// Once its request is handed over, a connection keeps none of it: a
    /// held request may wait for hours, and its payload be megabytes.
    func testAHeldConnectionKeepsNoneOfItsRequest() throws {
        let (connection, hook) = try connectionPair()
        let payload = Data(repeating: UInt8(ascii: " "), count: 100_000)
        DispatchQueue.global().async {
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = send(hook, raw.baseAddress! + offset, raw.count - offset, MSG_NOSIGNAL)
                    guard sent > 0 else { return }
                    offset += sent
                }
            }
            shutdown(hook, SHUT_WR)
        }
        let handedOver = Flag()
        queue.async {
            connection.readRequest(limit: 1_000_000) { request in
                if case .received(let data) = request, data.count == payload.count { handedOver.set() }
            }
        }
        XCTAssertTrue(wait(for: handedOver, timeout: 5), "the request was not handed over whole")
        XCTAssertEqual(connection.keptRequestBytesForTesting, 0, "the connection keeps its request")
        connection.cancel()
    }

    /// A hook that sends nothing, or part of its request and then nothing,
    /// never finishing it, is handed over as stalled once the idle timeout
    /// passes.
    func testAStalledRequestIsHandedOverAsStalled() throws {
        for sent in ["", #"{"hook_event_name":"#] {
            let (connection, hook) = try connectionPair()
            if !sent.isEmpty {
                _ = sent.withCString { send(hook, $0, strlen($0), MSG_NOSIGNAL) }
            }
            let stalled = Flag()
            queue.async {
                connection.readRequest(limit: 1_024, idleTimeout: 0.3) { request in
                    if case .stalled = request { stalled.set() }
                }
            }
            XCTAssertTrue(wait(for: stalled, timeout: 2), "a hook that sent \(sent.isEmpty ? "nothing" : "part of its request") was waited on for good")
            XCTAssertEqual(connection.keptRequestBytesForTesting, 0)
            connection.cancel()
        }
    }

    /// The idle timeout counts silence, not time: a request that comes slowly
    /// but steadily (a slow SSH link) gets through whole.
    func testASlowButSteadyRequestIsNotCutOff() throws {
        let (connection, hook) = try connectionPair()
        let chunks = 10
        let received = Flag()
        queue.async {
            connection.readRequest(limit: 1_024, idleTimeout: 0.3) { request in
                if case .received(let data) = request, data.count == chunks { received.set() }
            }
        }
        for _ in 0..<chunks {
            _ = "x".withCString { send(hook, $0, 1, MSG_NOSIGNAL) }
            usleep(100_000)  // a second in all: more than the idle timeout
        }
        shutdown(hook, SHUT_WR)
        XCTAssertTrue(wait(for: received, timeout: 2), "a slow but steady request was cut off")
        connection.cancel()
    }

    /// Steady is not forever: a hook that trickles a byte now and then, never
    /// silent for the idle timeout, is still cut off at the read deadline.
    func testATrickleIsCutOffAtTheReadDeadline() throws {
        let (connection, hook) = try connectionPair()
        let stalled = Flag()
        let started = Date()
        queue.async {
            connection.readRequest(limit: 1_024, idleTimeout: 0.3, deadline: 0.6) { request in
                if case .stalled = request { stalled.set() }
            }
        }
        let trickling = Flag()
        DispatchQueue.global().async {
            for _ in 0..<30 where !stalled.isSet {
                _ = "x".withCString { send(hook, $0, 1, MSG_NOSIGNAL) }
                usleep(100_000)  // three seconds in all
            }
            trickling.set()
        }
        XCTAssertTrue(wait(for: stalled, timeout: 2), "a trickle held its connection past the read deadline")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(connection.keptRequestBytesForTesting, 0)
        _ = wait(for: trickling, timeout: 4)
        connection.cancel()
    }

    /// The unfinished requests of a socket's connections share one budget:
    /// the connection that would pass it is dropped, and what a request took
    /// comes back once it is handed over.
    func testUnfinishedRequestsShareTheSocketsBudget() throws {
        let budget = HookReadBudget(limit: 100)
        let (first, firstHook) = try connectionPair()
        let (second, secondHook) = try connectionPair()
        let firstDone = Slot<HookConnection.Request>()
        let secondDone = Slot<HookConnection.Request>()
        queue.async {
            first.readRequest(limit: 1_024, budget: budget) { firstDone.set($0) }
            second.readRequest(limit: 1_024, budget: budget) { secondDone.set($0) }
        }
        _ = String(repeating: "a", count: 80).withCString { send(firstHook, $0, 80, MSG_NOSIGNAL) }
        let firstHeld = Flag()
        DispatchQueue.global().async {
            while self.queue.sync(execute: { budget.used }) < 80 { usleep(5_000) }
            firstHeld.set()
        }
        XCTAssertTrue(wait(for: firstHeld, timeout: 2), "the first request's bytes were not counted")
        _ = String(repeating: "b", count: 40).withCString { send(secondHook, $0, 40, MSG_NOSIGNAL) }
        XCTAssertTrue(wait(until: { secondDone.value != nil }, timeout: 2), "a request past the budget was read on")
        guard case .overBudget = secondDone.value else {
            return XCTFail("a request past the budget was not dropped: \(String(describing: secondDone.value))")
        }
        XCTAssertNil(firstDone.value, "the request within the budget was dropped")

        shutdown(firstHook, SHUT_WR)
        XCTAssertTrue(wait(until: { firstDone.value != nil }, timeout: 2))
        guard case .received(let data) = firstDone.value else {
            return XCTFail("the request within the budget did not get through: \(String(describing: firstDone.value))")
        }
        XCTAssertEqual(data.count, 80)
        XCTAssertEqual(queue.sync { budget.used }, 0, "a handed-over request kept its share of the budget")

        // A connection that closes mid-request gives its share back too.
        let (third, thirdHook) = try connectionPair()
        queue.async { third.readRequest(limit: 1_024, budget: budget) { _ in } }
        _ = String(repeating: "c", count: 90).withCString { send(thirdHook, $0, 90, MSG_NOSIGNAL) }
        XCTAssertTrue(wait(until: { self.queue.sync { budget.used } == 90 }, timeout: 2))
        third.cancel()
        XCTAssertTrue(wait(until: { self.queue.sync { budget.used } == 0 }, timeout: 2),
                      "a cancelled request kept its share of the budget")
        first.cancel()
        second.cancel()
    }

    /// Waits until `condition` holds; false after `timeout`.
    private func wait(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    /// The first answer is the one: a second, arriving while the first is
    /// still being written, is dropped, not spliced into it.
    func testTheFirstAnswerWins() throws {
        let (connection, hook) = try connectionPair()
        let first = Data(repeating: UInt8(ascii: "A"), count: 200_000)  // more than the socket holds
        connection.respond(first)
        connection.respond(Data("BBBB".utf8))

        let answer = readToEOF(hook)
        XCTAssertEqual(answer.count, first.count)
        XCTAssertEqual(answer, first, "a second answer was spliced into the first")
    }

    /// A watched connection closes the moment its hook goes, and not before.
    func testAWatchedHookIsSeenGoingAtOnce() throws {
        let (connection, hook) = try connectionPair(peerWatch: HookPeerWatch())
        let closed = closing(connection)
        shutdown(hook, SHUT_WR)

        connection.closeWhenPeerLeaves()
        XCTAssertFalse(wait(for: closed, timeout: 0.3), "a waiting hook was cut off")
        closeHook(hook)
        XCTAssertTrue(wait(for: closed, timeout: 0.5), "the hook's going was not seen at once")
    }

    /// With no kqueue to be had (the descriptors ran out), a held connection
    /// still sees its hook go, by asking its socket now and then — and
    /// leaves a waiting hook alone.
    func testAHookIsSeenGoingWithoutAKqueue() throws {
        let noKqueue = HookPeerWatch(makeKqueue: {
            errno = EMFILE
            return -1
        })
        let (connection, hook) = try connectionPair(peerWatch: noKqueue)
        let closed = closing(connection)
        shutdown(hook, SHUT_WR)

        connection.closeWhenPeerLeaves()
        XCTAssertFalse(wait(for: closed, timeout: HookConnection.peerPollInterval * 1.5), "a waiting hook was cut off")
        closeHook(hook)
        XCTAssertTrue(wait(for: closed, timeout: HookConnection.peerPollInterval * 3), "the hook's going went unnoticed")
    }
}

/// The listener's own concerns.
final class HookSocketListenerTests: XCTestCase {
    /// launchd starts the app with 256 descriptors; the island raises that
    /// toward what it wants, never past the hard limit and never lower.
    func testTheDescriptorLimitRisesTowardWhatTheIslandWants() {
        let wanted = HookSocketListener.wantedDescriptorLimit
        XCTAssertEqual(HookSocketListener.raisedDescriptorLimit(soft: 256, hard: .max), wanted)
        XCTAssertEqual(HookSocketListener.raisedDescriptorLimit(soft: 256, hard: 1_024), 1_024)
        XCTAssertNil(HookSocketListener.raisedDescriptorLimit(soft: 10_240, hard: .max))
        XCTAssertNil(HookSocketListener.raisedDescriptorLimit(soft: 256, hard: 256))
    }

    /// A path too long for a socket address is refused before anything is
    /// done to it: whatever is there stays.
    func testATooLongPathIsLeftAlone() throws {
        let path = NSTemporaryDirectory() + String(repeating: "x", count: 110) + ".sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("kept".utf8)))
        defer { unlink(path) }

        let listener = HookSocketListener(path: path, queue: DispatchQueue(label: "too-long")) { _ in }
        XCTAssertFalse(listener.start())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "start() removed what it could not listen on")
    }

    // MARK: - One island per socket

    /// An island is found where one listens — and only there: not at a stale
    /// socket a crash left, nor through a symlink, nor where nothing is.
    func testAnIslandIsFoundWhereOneListens() throws {
        let path = "/tmp/ci-one-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        XCTAssertNil(HookSocketListener.islandListening(at: path), "nothing there")
        try leaveSocket(at: path)
        XCTAssertNil(HookSocketListener.islandListening(at: path), "a stale socket")
        unlink(path)

        let listener = HookSocketListener(path: path, queue: DispatchQueue(label: "one-island")) { $0.cancel() }
        XCTAssertTrue(listener.start())
        defer {
            listener.stop()
            listener.removeSocketFile()
        }
        XCTAssertEqual(HookSocketListener.islandListening(at: path), getpid())
        let link = "/tmp/ci-one-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertEqual(symlink(path, link), 0)
        defer { unlink(link) }
        XCTAssertNil(HookSocketListener.islandListening(at: link), "through a symlink")
        XCTAssertNil(HookSocketListener.islandListening(at: path, uid: getuid() + 1), "another user's")
    }

    /// Another island already listening keeps its socket: a second one does
    /// not take it from under it. One of this process's own is replaced, as
    /// ever.
    func testASecondIslandLeavesTheFirstItsSocket() throws {
        let path = "/tmp/ci-one-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        // The other island: another process listening as this user.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        other.arguments = ["-c", """
            import socket, sys, time
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.bind(sys.argv[1])
            s.listen(8)
            print("ready", flush=True)
            time.sleep(30)
            """, path]
        let ready = Pipe()
        other.standardOutput = ready
        try other.run()
        defer { other.terminate() }
        _ = ready.fileHandleForReading.availableData  // "ready"
        let theirs = try XCTUnwrap(SocketPath.lstat(path))
        XCTAssertEqual(HookSocketListener.islandListening(at: path), other.processIdentifier)

        let second = HookSocketListener(path: path, queue: DispatchQueue(label: "second-island")) { $0.cancel() }
        XCTAssertFalse(second.start(), "a second island took the socket")
        let still = try XCTUnwrap(SocketPath.lstat(path))
        XCTAssertEqual(still.st_ino, theirs.st_ino, "the first island's socket was replaced")
        XCTAssertEqual(HookSocketListener.islandListening(at: path), other.processIdentifier)

        // Once it is gone, its stale socket is taken as before.
        other.terminate()
        other.waitUntilExit()
        let next = HookSocketListener(path: path, queue: DispatchQueue(label: "next-island")) { $0.cancel() }
        XCTAssertTrue(next.start())
        defer {
            next.stop()
            next.removeSocketFile()
        }
        // And one of this process's own is replaced.
        let replacement = HookSocketListener(path: path, queue: DispatchQueue(label: "replacement")) { $0.cancel() }
        XCTAssertTrue(replacement.start())
        defer {
            replacement.stop()
            replacement.removeSocketFile()
        }
        XCTAssertEqual(HookSocketListener.islandListening(at: path), getpid())
    }

    func testRaisingTheDescriptorLimitLiftsLaunchdsDefault() throws {
        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &saved), 0)
        defer {
            var restored = saved
            setrlimit(RLIMIT_NOFILE, &restored)
        }
        var launchd = saved
        launchd.rlim_cur = 256
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &launchd), 0)

        HookSocketListener.raiseDescriptorLimit()
        var raised = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &raised), 0)
        XCTAssertEqual(raised.rlim_cur, min(saved.rlim_max, HookSocketListener.wantedDescriptorLimit))
    }
}

/// Set once, from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A value set from any thread.
private final class Slot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

/// A hook client of the island's socket, writing the way hooks do.
private final class RawHook: @unchecked Sendable {
    /// Set once, from another thread.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        private var storedTimedOut = false
        var value: Data? { lock.withLock { stored } }
        /// The read gave up waiting: the island neither answered nor closed.
        var timedOut: Bool { lock.withLock { storedTimedOut } }
        func set(_ read: (data: Data, timedOut: Bool)) {
            lock.withLock {
                stored = read.data
                storedTimedOut = read.timedOut
            }
        }
    }

    private let fd: Int32
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func connect(to path: String) -> RawHook? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        return RawHook(fd: fd)
    }

    /// Connects, writes `payload`, half-closes and closes: a hook that does
    /// not wait for the island.
    static func sendAndClose(_ payload: String, to path: String) {
        guard let hook = connect(to: path) else { return }
        hook.write(payload)
        hook.close()
    }

    /// Writes `payload` and half-closes, as every hook does once it has written.
    func write(_ payload: String) {
        writeAll(Data(payload.utf8))
        shutdown(fd, SHUT_WR)
    }

    /// Writes `payload` and stops there, without the half-close that ends a
    /// request: a hook that stalled.
    func writeWithoutFinishing(_ payload: String) {
        writeAll(Data(payload.utf8))
    }

    /// Writes `data` (and half-closes) on another thread; then reads the
    /// answer to EOF when `thenRead`.
    func writeInBackground(_ data: Data, thenRead: Bool) -> Box {
        let box = Box()
        DispatchQueue.global().async { [self] in
            writeAll(data)
            shutdown(fd, SHUT_WR)
            if thenRead { box.set(readToEOF()) }
        }
        return box
    }

    /// Reads the answer to EOF on another thread, giving up after `timeout` seconds.
    func readAnswerInBackground(timeout: Int = 10) -> Box {
        let box = Box()
        DispatchQueue.global().async { [self] in box.set(readToEOF(timeout: timeout)) }
        return box
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = send(fd, raw.baseAddress! + offset, raw.count - offset, MSG_NOSIGNAL)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return  // the island stopped reading (an oversized request)
                }
            }
        }
    }

    private func readToEOF(timeout seconds: Int = 10) -> (data: Data, timedOut: Bool) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                answer.append(contentsOf: buffer[..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return (answer, count < 0 && errno == EAGAIN)
            }
        }
    }
}
