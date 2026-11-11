import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The socket a request arrives on names its machine. This Mac's socket gets
/// only this Mac's hooks, none of which names a remote host: a request there
/// that does is a local process passing itself off as a remote host, and is
/// answered with nothing. A remote host's socket applies that host's cwd
/// allow-list (#240), whatever host the request names. Throwaway sockets
/// under /tmp, never the user's.
@MainActor
final class HookServerOriginTests: XCTestCase {
    private var socketPath: String!
    private var appState: AppState!
    private var server: HookServer!

    override func setUp() {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        socketPath = "/tmp/ci-ho-\(UUID().uuidString.prefix(8)).sock"
        appState = AppState()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        appState = nil
        unlink(socketPath)
    }

    private func start(
        _ origin: HookOrigin,
        cwdFilter: @escaping @MainActor (String) -> String? = { _ in nil }
    ) {
        server = HookServer(appState: appState, socketPath: socketPath, origin: origin, hostCwdFilter: cwdFilter)
        XCTAssertTrue(server.start(), "HookServer did not listen on \(socketPath!)")
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message, file: file, line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func pump(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// What the island answers `payload`.
    private func exchange(_ payload: Data, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let exchange = HookExchange.send(payload, to: socketPath)
        pump(until: { exchange.isDone }, "no answer", file: file, line: line)
        return try XCTUnwrap(exchange.answer, "nothing listened", file: file, line: line)
    }

    private func exchange(_ payload: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        try exchange(Data(payload.utf8), file: file, line: line)
    }

    // MARK: - This Mac's socket

    func testThisMacsSocketRefusesARequestThatClaimsARemoteHost() throws {
        start(.local)
        let claims: [String: Data] = [
            "host id": Data(#"{"hook_event_name":"PermissionRequest","session_id":"f1","cwd":"/w","_source":"claude","tool_name":"Bash","tool_input":{"command":"make"},"_remote_host_id":"devbox"}"#.utf8),
            "host name": Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"f2","cwd":"/w","prompt":"p","_source":"claude","_remote_host_name":"Dev Box"}"#.utf8),
            "edge facts": Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"f3","cwd":"/w","prompt":"p","_edge":{"v":1,"source":"claude","waits":true,"host":{"id":"devbox","name":"Dev Box"}}}"#.utf8),
            "an escaped key": Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"f4","cwd":"/w","prompt":"p","_source":"claude","_remote_host_id":"devbox"}"#.utf8),
            "UTF-16": try XCTUnwrap(#"{"hook_event_name":"UserPromptSubmit","session_id":"f5","cwd":"/w","prompt":"p","_source":"claude","_remote_host_id":"devbox"}"#.data(using: .utf16LittleEndian)),
        ]
        for (name, claim) in claims {
            XCTAssertEqual(try exchange(claim), Data(), "\(name): answered with nothing")
        }
        pump(for: 0.2)
        XCTAssertTrue(appState.sessions.isEmpty, "no card, local or remote: \(appState.sessions.keys.sorted())")
        XCTAssertTrue(appState.permissionQueue.isEmpty, "no request is held")
    }

    func testThisMacsOwnHooksPassAsBefore() throws {
        start(.local)
        XCTAssertEqual(
            try exchange(#"{"hook_event_name":"UserPromptSubmit","session_id":"local-1","cwd":"/w","prompt":"p","_source":"claude","_remote_host_id":""}"#),
            Data("{}".utf8)
        )
        pump(until: { self.appState.sessions["local-1"] != nil }, "the local hook never reached the island")
        XCTAssertFalse(try XCTUnwrap(appState.sessions["local-1"]).isRemote)
    }

    // MARK: - A remote host's socket

    /// The allow-list is the socket's host's: naming another host, or none,
    /// does not get a request past it.
    func testTheCwdFilterIsTheSocketsHosts() throws {
        start(.remoteHost(id: "host-1", name: "Dev Box"), cwdFilter: { $0 == "host-1" ? "/home/me" : nil })
        for (session, extra) in [("other", #","_remote_host_id":"host-2""#), ("none", "")] {
            _ = try exchange(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)","cwd":"/home/colleague/x","prompt":"p","_source":"claude"\#(extra)}"#)
        }
        _ = try exchange(#"{"hook_event_name":"UserPromptSubmit","session_id":"mine","cwd":"/home/me/proj","prompt":"p","_source":"claude","_remote_host_id":"host-2"}"#)
        pump(until: { self.appState.sessions["remote:host-1:mine"] != nil }, "a session in the allowed folder never arrived")
        pump(for: 0.2)
        XCTAssertEqual(Array(appState.sessions.keys), ["remote:host-1:mine"])
    }
}
