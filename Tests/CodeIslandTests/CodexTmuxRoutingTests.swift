import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class CodexTmuxRoutingTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1000)
    private let panes = [CodexTmuxRouting.Pane(id: "%7", pid: 70),
                         CodexTmuxRouting.Pane(id: "%14", pid: 140)]

    private func session(pid: pid_t) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "codex"
        session.cliPid = pid
        session.cliStartTime = started
        session.tmuxPane = "%14"
        session.tmuxEnv = "/tmp/tmux-test/default,1,0"
        return session
    }

    func testSharedDaemonCannotClaimInheritedPaneForMultipleSessions() {
        for _ in 0..<3 {
            let result = CodexTmuxRouting.resolve(session: session(pid: 97662), panes: panes,
                parentOf: { [97662: 24422, 24422: 1][$0] }, startTime: { _ in self.started })
            XCTAssertEqual(result, .ambiguous)
        }
    }

    func testRealCLIUsesCurrentProcessTreeInsteadOfStalePane() {
        let result = CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { [700: 71, 71: 70, 70: 1][$0] }, startTime: { _ in self.started })
        XCTAssertEqual(result.pane?.id, "%7")
    }

    func testTwoCLIsInSameDirectoryResolveToDifferentPanes() {
        let parents: [pid_t: pid_t] = [700: 70, 1400: 140]
        for (pid, pane) in [(pid_t(700), "%7"), (pid_t(1400), "%14")] {
            var input = session(pid: pid)
            input.cwd = "/same/project"
            let result = CodexTmuxRouting.resolve(session: input, panes: panes,
                parentOf: { parents[$0] }, startTime: { _ in self.started })
            XCTAssertEqual(result.pane?.id, pane)
        }
    }

    /// Nothing to verify against: the hook's pane stays the target, as it is
    /// for every other source, instead of failing the jump.
    func testGoneProcessReusedPIDAndEmptyServerAreUnverified() {
        // Process gone.
        XCTAssertEqual(CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { _ in 70 }, startTime: { _ in nil }), .unverified)
        // PID reused by a younger process.
        XCTAssertEqual(CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { _ in 70 }, startTime: { _ in self.started.addingTimeInterval(10) }), .unverified)
        // No pane parsed from the server's answer.
        XCTAssertEqual(CodexTmuxRouting.resolve(session: session(pid: 700), panes: [],
            parentOf: { _ in 70 }, startTime: { _ in self.started }), .unverified)
        // No PID at all.
        var input = session(pid: 700)
        input.cliPid = nil
        XCTAssertEqual(CodexTmuxRouting.resolve(session: input, panes: panes,
            parentOf: { _ in nil }, startTime: { _ in self.started }), .unverified)
    }

    func testLiveProcessOutsideEveryPaneIsAmbiguous() {
        // Closed pane: the live process is under no pane of this server.
        XCTAssertEqual(CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { [700: 1][$0] }, startTime: { _ in self.started }), .ambiguous)
        // An ancestry cycle stops the walk.
        XCTAssertEqual(CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { _ in 700 }, startTime: { _ in self.started }), .ambiguous)
    }

    func testSharedDaemonResolvesUniqueLiveTitleAndCwd() {
        var input = session(pid: 97662)
        input.sessionTitle = "Investigate routing"
        input.cwd = "/work/project"
        let live = CodexTmuxRouting.Pane(id: "%31", pid: 310,
            title: "⠼ Investigate routing | project", cwd: "/work/project", command: "codex")
        let result = CodexTmuxRouting.resolve(session: input, panes: panes + [live],
            parentOf: { _ in 1 }, startTime: { _ in self.started })
        XCTAssertEqual(result.pane?.id, "%31")
        XCTAssertEqual(CodexTmuxRouting.resolve(session: input, panes: [live, live],
            parentOf: { _ in 1 }, startTime: { _ in self.started }), .ambiguous)
        var exited = live
        exited.command = "zsh"
        XCTAssertEqual(CodexTmuxRouting.resolve(session: input, panes: [exited],
            parentOf: { _ in 1 }, startTime: { _ in self.started }), .ambiguous)
        var unrelated = live
        unrelated.cwd = "/other/project"
        XCTAssertEqual(CodexTmuxRouting.resolve(session: input, panes: [unrelated],
            parentOf: { _ in 1 }, startTime: { _ in self.started }), .ambiguous)
        unrelated = live
        unrelated.title = "Other thread | project"
        XCTAssertEqual(CodexTmuxRouting.resolve(session: input, panes: [unrelated],
            parentOf: { _ in 1 }, startTime: { _ in self.started }), .ambiguous)
    }

    func testParsePanesKeepsTabsInTitleAndSkipsMalformedLines() {
        let output = "%3\t301\t$1\tcodex\t/work/project\t⠼ Fix\ttabs | project\n"
            + "garbage\n"
            + "%4\tnot-a-pid\t$1\tzsh\t/tmp\ttitle\n"
        let parsed = CodexTmuxRouting.parsePanes(output)
        XCTAssertEqual(parsed, [CodexTmuxRouting.Pane(id: "%3", pid: 301, title: "⠼ Fix\ttabs | project",
                                                      cwd: "/work/project", command: "codex", session: "$1")])
    }

    func testParseClients() {
        XCTAssertEqual(CodexTmuxRouting.parseClients("/dev/ttys001\t$0\n/dev/ttys004\t$2\n\n"),
                       [.init(tty: "/dev/ttys001", session: "$0"), .init(tty: "/dev/ttys004", session: "$2")])
        XCTAssertEqual(CodexTmuxRouting.parseClients(""), [])
    }

    /// Several attached clients used to fail the jump unless the hook's client
    /// was still attached; detached servers failed it too.
    func testClientChoicePrefersOneAlreadyShowingThePanesSession() {
        let pane = CodexTmuxRouting.Pane(id: "%9", pid: 90, session: "$2")
        let onOther = CodexTmuxRouting.Client(tty: "/dev/ttys001", session: "$0")
        let onPane = CodexTmuxRouting.Client(tty: "/dev/ttys004", session: "$2")
        let alsoOnPane = CodexTmuxRouting.Client(tty: "/dev/ttys007", session: "$2")

        // The hook's client wins among those already showing the session.
        XCTAssertEqual(CodexTmuxRouting.client(for: pane, clients: [onOther, onPane, alsoOnPane],
                                               preferred: "/dev/ttys007"), "/dev/ttys007")
        // A client showing the session beats the hook's client elsewhere.
        XCTAssertEqual(CodexTmuxRouting.client(for: pane, clients: [onOther, onPane],
                                               preferred: "/dev/ttys001"), "/dev/ttys004")
        // Nobody shows it: the hook's client if still attached…
        XCTAssertEqual(CodexTmuxRouting.client(for: pane, clients: [onOther, .init(tty: "/dev/ttys005", session: "$1")],
                                               preferred: "/dev/ttys001"), "/dev/ttys001")
        // …else the only client…
        XCTAssertEqual(CodexTmuxRouting.client(for: pane, clients: [onOther],
                                               preferred: "/dev/ttys099"), "/dev/ttys001")
        // …else tmux's own choice.
        XCTAssertNil(CodexTmuxRouting.client(for: pane, clients: [onOther, .init(tty: "/dev/ttys005", session: "$1")],
                                             preferred: "/dev/ttys099"))
        XCTAssertNil(CodexTmuxRouting.client(for: pane, clients: [], preferred: "/dev/ttys001"))
    }

    func testProbeAgainstIsolatedTmuxServer() throws {
        let bin = "/opt/homebrew/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: bin) else { throw XCTSkip("tmux not installed") }
        // Dedicated server on a socket this test owns: never touches the user's
        // sessions, and the socket file tmux leaves behind is removed with it.
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-routing-\(UUID().uuidString.prefix(8))").path
        guard ProcessRunner.run(path: bin, args: ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "routing", "sleep 30"], timeout: 3) != nil else {
            XCTFail("Could not start isolated tmux server")
            return
        }
        defer {
            _ = ProcessRunner.run(path: bin, args: ["-S", socket, "kill-server"], timeout: 3)
            try? FileManager.default.removeItem(atPath: socket)
        }
        let data = try XCTUnwrap(ProcessRunner.run(path: bin,
            args: ["-S", socket, "display-message", "-p", "#{pane_pid}\t#{pane_id}\t#{session_id}"], timeout: 3))
        let fields = try XCTUnwrap(String(data: data, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        XCTAssertEqual(fields.count, 3)
        guard fields.count == 3 else { return }
        var input = session(pid: try XCTUnwrap(pid_t(fields[0])))
        input.cliStartTime = nil
        input.tmuxEnv = "\(socket),1,0"
        let located = CodexTmuxRouting.probe(session: input, tmuxPath: bin).pane
        XCTAssertEqual(located?.id, String(fields[1]))
        XCTAssertEqual(located?.session, String(fields[2]))
        input.cliPid = getpid() // The test runner is not a child of that pane.
        XCTAssertEqual(CodexTmuxRouting.probe(session: input, tmuxPath: bin), .ambiguous)
        // The entry point the jump and the visibility check share: a Codex
        // session is second-guessed, the same session from another source is not.
        XCTAssertEqual(CodexTmuxRouting.resolution(for: input, tmuxPath: bin), .ambiguous)
        var claude = input
        claude.source = "claude"
        XCTAssertEqual(CodexTmuxRouting.resolution(for: claude, tmuxPath: bin), .unverified)
        // No server on the socket: nothing to verify against.
        input.tmuxEnv = "\(socket)-missing,1,0"
        XCTAssertEqual(CodexTmuxRouting.probe(session: input, tmuxPath: bin), .unverified)
    }

    func testResolutionKeepsTheHookPaneWithoutTmuxOrAPane() {
        XCTAssertEqual(CodexTmuxRouting.resolution(for: session(pid: 700), tmuxPath: nil), .unverified)
        var paneless = session(pid: 700)
        paneless.tmuxPane = nil
        XCTAssertEqual(CodexTmuxRouting.resolution(for: paneless, tmuxPath: "/usr/bin/false"), .unverified)
    }

    /// The jump check reads the same resolution as the jump: a session whose
    /// jump could only raise its terminal never counts as landed.
    func testJumpCheckDoesNotClaimAnUnlocatableSession() {
        let input = session(pid: 700)
        installVisibilityProbe(.init(isTerminalFrontmost: { _ in true },
                                     isSessionTabVisible: { _ in false },
                                     isSessionLocatable: { _ in false }))
        XCTAssertFalse(TerminalVisibilityDetector.didJumpLand(input))
        installVisibilityProbe(.init(isTerminalFrontmost: { _ in true },
                                     isSessionTabVisible: { _ in false },
                                     isSessionLocatable: { _ in true }))
        XCTAssertTrue(TerminalVisibilityDetector.didJumpLand(input))
        // The session's own tab showing is a landed jump, whatever else holds.
        installVisibilityProbe(.init(isTerminalFrontmost: { _ in false },
                                     isSessionTabVisible: { _ in true },
                                     isSessionLocatable: { _ in false }))
        XCTAssertTrue(TerminalVisibilityDetector.didJumpLand(input))
        // Probes that don't answer it keep the app-level check.
        installVisibilityProbe(.terminalInFront { _ in true })
        XCTAssertTrue(TerminalVisibilityDetector.didJumpLand(input))
        installVisibilityProbe(.unknown)
        XCTAssertFalse(TerminalVisibilityDetector.didJumpLand(input))
    }
}
