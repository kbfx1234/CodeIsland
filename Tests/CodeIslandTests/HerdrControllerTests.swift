import XCTest
import CodeIslandCore
@testable import CodeIsland

final class HerdrControllerTests: XCTestCase {
    func testIdentityRequiresPaneAndAbsoluteSocket() {
        var session = SessionSnapshot()
        session.herdrPaneId = " w1:p2 "
        session.herdrSocketPath = " /tmp/herdr.sock "
        session.herdrBinaryPath = " /tmp/herdr "

        XCTAssertEqual(
            HerdrController.identity(from: session),
            HerdrRoutingIdentity(
                paneId: "w1:p2",
                socketPath: "/tmp/herdr.sock",
                binaryPath: "/tmp/herdr"
            )
        )

        session.herdrSocketPath = "relative.sock"
        XCTAssertNil(HerdrController.identity(from: session))
    }

    func testFocusUsesCapturedSocketAndTimeout() throws {
        let binary = try temporaryExecutable()
        var invocation: Invocation?
        let identity = HerdrRoutingIdentity(
            paneId: "w2:p1",
            socketPath: "/tmp/named/herdr.sock",
            binaryPath: binary.path
        )

        let focused = HerdrController.focus(identity) { path, args, env, timeout in
            invocation = Invocation(path: path, args: args, env: env, timeout: timeout)
            return Data()
        }

        XCTAssertTrue(focused)
        XCTAssertEqual(invocation?.path, binary.path)
        XCTAssertEqual(invocation?.args, ["agent", "focus", "w2:p1"])
        XCTAssertEqual(invocation?.env["HERDR_SOCKET_PATH"], "/tmp/named/herdr.sock")
        XCTAssertEqual(invocation?.timeout, 2)
    }

    func testIsFocusedParsesAgentResponse() throws {
        let binary = try temporaryExecutable()
        let identity = HerdrRoutingIdentity(
            paneId: "w1:p1",
            socketPath: "/tmp/herdr.sock",
            binaryPath: binary.path
        )
        var invocation: Invocation?

        let focused = HerdrController.isFocused(identity) { path, args, env, timeout in
            invocation = Invocation(path: path, args: args, env: env, timeout: timeout)
            return Data(#"{"result":{"agent":{"focused":true}}}"#.utf8)
        }

        XCTAssertTrue(focused)
        XCTAssertEqual(invocation?.args, ["agent", "get", "w1:p1"])
        XCTAssertEqual(invocation?.timeout, 1)
    }

    func testIsFocusedRejectsMalformedOrUnfocusedResponse() throws {
        let binary = try temporaryExecutable()
        let identity = HerdrRoutingIdentity(
            paneId: "w1:p1",
            socketPath: "/tmp/herdr.sock",
            binaryPath: binary.path
        )

        XCTAssertFalse(HerdrController.isFocused(identity) { _, _, _, _ in
            Data(#"{"result":{"agent":{"focused":false}}}"#.utf8)
        })
        XCTAssertFalse(HerdrController.isFocused(identity) { _, _, _, _ in Data("nope".utf8) })
        XCTAssertFalse(HerdrController.focus(identity) { _, _, _, _ in nil })
    }

    func testRoutingPreservesRemoteAndNestedMultiplexerPrecedence() {
        var session = SessionSnapshot()
        session.herdrPaneId = "w1:p1"
        session.herdrSocketPath = "/tmp/herdr.sock"
        XCTAssertTrue(HerdrController.shouldRoute(session))

        session.tmuxPane = "%1"
        XCTAssertFalse(HerdrController.shouldRoute(session))
        session.tmuxPane = nil
        session.zellijPaneId = "3"
        XCTAssertFalse(HerdrController.shouldRoute(session))
        session.zellijPaneId = nil
        session.remoteHostId = "remote"
        XCTAssertFalse(HerdrController.shouldRoute(session))
    }

    private struct Invocation {
        let path: String
        let args: [String]
        let env: [String: String]
        let timeout: TimeInterval
    }

    /// An empty executable called `name` in a directory of its own.
    private func temporaryExecutable(named name: String = "herdr") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func makeEvent(_ payload: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    // MARK: - What may be run

    /// The pane's env names the binary, and the payload carries it: a path to
    /// any other executable (a shell, `rm`, a script) used to be run with
    /// `agent get <pane>` by every Smart Suppress check, no click needed.
    func testCapturedBinaryThatIsNotHerdrIsNeverRun() throws {
        let impostor = try temporaryExecutable(named: "not-herdr")
        let identity = HerdrRoutingIdentity(
            paneId: "w1:p1",
            socketPath: "/tmp/herdr.sock",
            binaryPath: impostor.path
        )
        var ran: [String] = []

        _ = HerdrController.isFocused(identity) { path, _, _, _ in
            ran.append(path)
            return Data(#"{"result":{"agent":{"focused":true}}}"#.utf8)
        }
        _ = HerdrController.focus(identity) { path, _, _, _ in
            ran.append(path)
            return Data()
        }

        XCTAssertFalse(ran.contains(impostor.path), "ran \(ran)")
        XCTAssertTrue(ran.allSatisfy { ($0 as NSString).lastPathComponent == "herdr" }, "ran \(ran)")
    }

    func testOnlyAnAbsolutePathToAFileCalledHerdrIsAccepted() {
        XCTAssertTrue(HerdrController.isHerdrBinaryPath("/opt/homebrew/bin/herdr"))
        XCTAssertTrue(HerdrController.isHerdrBinaryPath("/Users/me/.cargo/bin/herdr"))

        XCTAssertFalse(HerdrController.isHerdrBinaryPath("/bin/sh"))
        XCTAssertFalse(HerdrController.isHerdrBinaryPath("/usr/bin/osascript"))
        XCTAssertFalse(HerdrController.isHerdrBinaryPath("herdr"), "relative")
        XCTAssertFalse(HerdrController.isHerdrBinaryPath("/tmp/herdr-helper"))
        XCTAssertFalse(HerdrController.isHerdrBinaryPath("/tmp/herdr/.."))
        XCTAssertFalse(HerdrController.isHerdrBinaryPath("/tmp/herdr.sh"))
    }

    func testRejectedCapturedBinaryFallsBackToAWellKnownHerdr() {
        let identity = HerdrRoutingIdentity(paneId: "w1:p1", socketPath: "/tmp/herdr.sock", binaryPath: "/bin/sh")
        let installed = "/usr/local/bin/herdr"

        XCTAssertEqual(HerdrController.executable(for: identity) { $0 == "/bin/sh" || $0 == installed }, installed)
        XCTAssertNil(HerdrController.executable(for: identity) { $0 == "/bin/sh" })
    }

    func testPaneIdShapedLikeAnOptionIsNotRouted() {
        var session = SessionSnapshot()
        session.herdrPaneId = "--help"
        session.herdrSocketPath = "/tmp/herdr.sock"

        XCTAssertNil(HerdrController.identity(from: session))
        XCTAssertFalse(HerdrController.shouldRoute(session))
    }

    // MARK: - Remote sessions

    func testRemoteSessionHasNoHerdrIdentity() {
        var session = SessionSnapshot()
        session.herdrPaneId = "w1:p1"
        session.herdrSocketPath = "/tmp/herdr.sock"
        session.herdrBinaryPath = "/opt/homebrew/bin/herdr"
        session.remoteHostId = "devbox"

        XCTAssertNil(HerdrController.identity(from: session), "its pane is on its own host")
    }

    /// A remote host's hook never records a Herdr route — including the
    /// first hook of a card that a subagent's hook created, which only fills
    /// gaps and so used to leave the card looking local.
    func testRemoteHookNeverRecordsAHerdrRoute() throws {
        let herdr: [String: Any] = [
            "_remote_host_id": "devbox",
            "_herdr_pane_id": "w1:p1",
            "_herdr_socket_path": "/tmp/herdr.sock",
            "_herdr_bin_path": "/tmp/payload/herdr",
        ]
        let hooks: [(String, [String: Any])] = [
            ("SessionStart", [:]),
            ("PreToolUse", ["tool_name": "Bash"]),
            ("PreToolUse", ["tool_name": "Bash", "agent_id": "sub-1", "agent_type": "general-purpose"]),
        ]
        for (name, extra) in hooks {
            var payload: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/home/me/project"]
            payload.merge(herdr) { _, new in new }
            payload.merge(extra) { _, new in new }
            let event = try makeEvent(payload)
            var sessions: [String: SessionSnapshot] = [:]
            _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

            let card = try XCTUnwrap(sessions[event.sessionId ?? ""], name)
            XCTAssertNil(card.herdrPaneId, "\(name) \(extra)")
            XCTAssertNil(card.herdrBinaryPath, "\(name) \(extra)")
            XCTAssertFalse(HerdrController.shouldRoute(card), "\(name) \(extra)")
        }
    }
}
