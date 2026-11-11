import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The socket the hook's host has on the island: requests there are its own.
private let buildBox = HookOrigin.remoteHost(id: "host-1", name: "Build Box")

/// #377 over Remote-SSH: Cursor runs the Claude Code hooks it imports, so on a
/// remote host its events reach the remote hook as CODEISLAND_SOURCE=claude.
/// These tests run the shipped codeisland-remote-hook.py's `main()` against a
/// throwaway socket and read what the island makes of what it sends: the
/// hook sends facts (`_edge`), HookServer interprets them (HookIntake).
@MainActor
final class RemoteHookCursorPayloadTests: XCTestCase {
    private var sandbox: URL!
    private var hookURL: URL!
    private var socketPath: String!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let source = try XCTUnwrap(RemoteInstaller.remoteHookSource(), "remote hook resource missing")
        hookURL = sandbox.appendingPathComponent("codeisland-remote-hook.py")
        try Data(source.utf8).write(to: hookURL)
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        socketPath = "/tmp/ci-rh-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Feeds `input` to the hook's `main()` with CODEISLAND_SOURCE=claude and
    /// returns the event the island reads from what it sent, or nil when it
    /// sent nothing.
    private func sentPayload(for input: [String: Any]) throws -> [String: Any]? {
        guard let sent = try rawSentPayload(for: input) else { return nil }
        XCTAssertNotNil(sent["_edge"], "the hook sends facts")
        XCTAssertNil(sent["_source"], "and leaves interpreting them to the island")
        guard case .route(let routed, let edge) = HookServer.intake(try JSONSerialization.data(withJSONObject: sent), origin: buildBox) else {
            XCTFail("the island answered nothing")
            return nil
        }
        XCTAssertNotNil(edge)
        return try JSONSerialization.jsonObject(with: routed) as? [String: Any]
    }

    private func rawSentPayload(for input: [String: Any]) throws -> [String: Any]? {
        let driver = """
        import importlib.util, io, json, os, socket, sys, threading
        hook_path, socket_path, stdin_text = sys.argv[1], sys.argv[2], sys.argv[3]
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(socket_path)
        server.listen(1)
        server.settimeout(5)
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
            received["payload"] = json.loads(data)
            conn.close()
        thread = threading.Thread(target=serve)
        thread.start()
        spec = importlib.util.spec_from_file_location("hook", hook_path)
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        sys.stdin = io.TextIOWrapper(io.BytesIO(stdin_text.encode("utf-8")), encoding="utf-8")
        hook.main()
        thread.join(6)
        print(json.dumps(received.get("payload")))
        """
        let stdinData = try JSONSerialization.data(withJSONObject: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, socketPath, String(decoding: stdinData, as: UTF8.self)]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandbox.path
        environment["CODEISLAND_SOCKET_PATH"] = socketPath
        environment["CODEISLAND_SOURCE"] = "claude"
        environment["CODEISLAND_REMOTE_HOST_ID"] = "host-1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "hook driver failed: \(err)")
        return try JSONSerialization.jsonObject(with: out, options: .fragmentsAllowed) as? [String: Any]
    }

    func testCursorPayloadIsSentAsCursor() throws {
        let payload = try XCTUnwrap(sentPayload(for: [
            "hook_event_name": "stop",
            "session_id": "conv-1",
            "conversation_id": "conv-1",
            "cursor_version": "3.25.9",
            "cwd": "/work/proj",
            "status": "completed",
        ]))
        XCTAssertEqual(payload["_source"] as? String, "cursor")
        XCTAssertEqual(payload["_remote_host_id"] as? String, "host-1")
    }

    func testClaudeCodePayloadStaysClaude() throws {
        let payload = try XCTUnwrap(sentPayload(for: [
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "cwd": "/work/proj",
        ]))
        XCTAssertEqual(payload["_source"] as? String, "claude")
    }

    func testBlankCursorVersionIsNotCursor() throws {
        let payload = try XCTUnwrap(sentPayload(for: [
            "hook_event_name": "Stop",
            "session_id": "sess-2",
            "cursor_version": "  ",
            "cwd": "/work/proj",
        ]))
        XCTAssertEqual(payload["_source"] as? String, "claude")
    }
}
