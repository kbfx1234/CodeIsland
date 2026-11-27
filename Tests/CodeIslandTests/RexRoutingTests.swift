import XCTest
@testable import CodeIsland
import CodeIslandCore

final class RexRoutingTests: XCTestCase {
    func testRexIsRecognizedAsAWindowedTerminal() {
        XCTAssertTrue(TerminalActivator.knownTerminals.contains {
            $0.bundleId == "com.superlogical.rex"
        })
    }

    func testRexBinaryPathPrefersTheInheritedServerDirectory() {
        let path = TerminalActivator.rexBinaryPath(
            environment: ["REX_BIN_DIR": "/custom/rex/bin"],
            fileExists: { $0 == "/custom/rex/bin/rex" }
        )
        XCTAssertEqual(path, "/custom/rex/bin/rex")
    }

    func testJumpUsesTheBlocksCurrentSessionAndLocalDesktopClient() {
        let clients = """
        {"clients":[
          {"client_id":"remote","connection_state":"connected","info":{"kind":"app"},
           "principal":{"transport":"tcp","pid":42}},
          {"client_id":"cli","connection_state":"connected","info":{"kind":"cli"},
           "principal":{"transport":"unix","pid":42}},
          {"client_id":"local","connection_state":"connected","info":{"kind":"app"},
           "principal":{"transport":"unix","pid":42}}
        ]}
        """
        var calls: [[String]] = []
        RexRouting.focus(blockID: "block", savedSessionID: "old-session", appPID: 42) { args in
            calls.append(args)
            switch args {
            case ["block", "inspect", "--json", "--", "block"]:
                return Data(#"{"session_id":"new-session","block":{"window_id":"win"}}"#.utf8)
            case ["client", "ls", "--json"]:
                return Data(clients.utf8)
            case ["-C", "local", "do", "session.select", "session_id=new-session", "window_id=win"]:
                // The server-side block focus still works with Remote Control off.
                return nil
            default:
                return Data()
            }
        }
        XCTAssertEqual(calls, [
            ["block", "inspect", "--json", "--", "block"],
            ["client", "ls", "--json"],
            ["-C", "local", "do", "session.select", "session_id=new-session", "window_id=win"],
            ["block", "focus", "-s", "new-session", "--", "block"],
        ])
    }

    func testTmuxJumpPrefersTheVerifiedRexClientAlreadyShowingTheSession() {
        let clients: [CodexTmuxRouting.Client] = [
            .init(tty: "/dev/ttys001", session: "$1", pid: 21),
            .init(tty: "/dev/ttys002", session: "$2", pid: 22),
            .init(tty: "/dev/ttys003", session: "$2", pid: 23),
        ]
        let blocks = [21: "other-session", 22: "stale-block", 23: "target-block"]
        let pids = ["stale-block": 99, "target-block": 23, "other-session": 21]
        var checked: [String] = []
        let target = RexRouting.tmuxTarget(
            pane: "%9", sessionID: "$2", preferredTTY: "/dev/ttys001",
            clients: clients, environment: { pid in blocks[Int(pid)].map { ["REX_BLOCK": $0] } }
        ) { args in
            let block = args[3]
            checked.append(block)
            guard let pid = pids[block] else { return nil }
            return Data("{\"foreground\":{\"pid\":\(pid)}}".utf8)
        }

        XCTAssertEqual(checked, ["stale-block", "target-block"])
        XCTAssertEqual(target?.blockID, "target-block")
        XCTAssertEqual(target?.client.tty, "/dev/ttys003")
        XCTAssertEqual(target?.paneID, "%9")
    }

    func testRexTmuxJumpRequiresMoreThanAppFocus() {
        var session = SessionSnapshot()
        session.rexBlockId = "block"
        session.tmuxPane = "%9"

        installVisibilityProbe(.init(
            isTerminalFrontmost: { _ in true }, isSessionTabVisible: { _ in false }
        ))
        XCTAssertFalse(TerminalVisibilityDetector.didJumpLand(session))

        installVisibilityProbe(.init(
            isTerminalFrontmost: { _ in true }, isSessionTabVisible: { _ in true }
        ))
        XCTAssertTrue(TerminalVisibilityDetector.didJumpLand(session))
    }
}
