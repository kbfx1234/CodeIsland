import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Claude Code's native binary is multicall. Besides the CLI, the same file
/// runs the grep / find / ripgrep that its Bash tool's shell and its Grep tool
/// use (`exec -a ugrep|bfs|rg <binary>`), and its background-session
/// machinery (`claude bg-pty-host`, `claude bg-spare`, daemon workers). Discovery
/// took any of them for a session's CLI. On a real Mac, a session in `~` was
/// bound to and watched on a `ugrep` its shell ran, so the card went away when
/// the grep did, and once the grep's shell had gone, the orphan sweep would
/// SIGTERM the grep and drop the card.
///
/// The argv shapes are the ones those processes had on that Mac, with
/// patterns, prompts, ids and paths replaced.
final class ClaudeCodeHelperProcessTests: XCTestCase {
    private let versionsDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/claude/versions"
    private var binary: String { versionsDir + "/2.1.309" }

    private var cliInvocations: [[String]] {
        [
            ["claude"],
            ["claude", "--dangerously-skip-permissions"],
            ["claude", "--resume", "00000000-0000-4000-8000-000000000000"],
            ["claude", "-r"],
            ["claude", "--continue"],
            ["claude", "-c"],
            ["claude", "-p", "<prompt>"],
            ["claude", "--print", "--output-format", "stream-json", "<prompt>"],
            ["claude", "<prompt>"],
            ["claude", "--model", "opus", "<prompt>"],
            // The versioned binary started by its own path.
            [binary],
            ["/Users/u/.local/bin/claude", "--resume"],
        ]
    }

    private var toolInvocations: [[String]] {
        [
            [
                "ugrep", "-G", "--ignore-files", "--hidden", "-I", "--exclude-dir=.git", "--exclude-dir=.svn",
                "--exclude-dir=.hg", "--exclude-dir=.bzr", "--exclude-dir=.jj", "--exclude-dir=.sl", "-E",
                "--line-buffered", "<pattern>",
            ],
            ["bfs", "-S", "dfs", "-regextype", "findutils-default", ".", "-name", "<glob>"],
            ["rg", "--no-config", "--files", "--hidden", "<path>"],
            ["apply-seccomp", "<args>"],
        ]
    }

    private var backgroundHelperInvocations: [[String]] {
        [
            ["claude bg-pty-host", "--bg-pty-host", "/tmp/bg/pty.sock", "200", "50", "--", binary, "--bg-spare", "/tmp/bg/claim.sock"],
            ["claude bg-spare", "--bg-spare", "/tmp/bg/claim.sock"],
            // argv[0] left alone (Claude Code does not set it on Windows).
            [binary, "--bg-spare", "/tmp/bg/claim.sock"],
            [binary, "--bg-pty-host", "/tmp/bg/pty.sock", "80", "24", "--", "/bin/zsh"],
            ["claude", "--daemon-worker", "local_bash"],
            ["claude", "--daemon-worker", "in_process_teammate", "2"],
            ["claude", "--preload"],
            ["claude", "--gh-standin", "54321", "/tmp/ca.pem", "--", "pr", "view"],
            ["claude", "--claude-in-chrome-mcp"],
            ["claude", "--chrome-native-host"],
            ["claude", "--computer-use-mcp"],
        ]
    }

    private var nonSessionCommands: [[String]] {
        [
            ["claude", "mcp", "serve"],
            ["claude", "mcp", "add", "<name>", "<command>"],
            ["claude", "doctor"],
            ["claude", "update"],
            ["claude", "install", "stable"],
            ["claude", "uninstall"],
            ["claude", "config", "list"],
            ["claude", "plugin", "install", "<plugin>"],
            ["claude", "setup-token"],
            ["claude", "auth", "login"],
        ]
    }

    private var nonCLIInvocations: [[String]] {
        toolInvocations + backgroundHelperInvocations + nonSessionCommands
    }

    // MARK: - Which argv is the CLI

    func testInteractivePrintAndResumedSessionsAreTheCLI() {
        for argv in cliInvocations {
            XCTAssertTrue(AgentProcessFinder.isClaudeCodeCLIInvocation(arguments: argv), "\(argv)")
        }
    }

    func testToolsTheBinaryRunsAsAreNotTheCLI() {
        for argv in toolInvocations {
            XCTAssertFalse(AgentProcessFinder.isClaudeCodeCLIInvocation(arguments: argv), "\(argv)")
        }
    }

    func testBackgroundMachineryIsNotTheCLI() {
        for argv in backgroundHelperInvocations {
            XCTAssertFalse(AgentProcessFinder.isClaudeCodeCLIInvocation(arguments: argv), "\(argv)")
        }
    }

    func testSubcommandsThatRunNoSessionAreNotTheCLI() {
        for argv in nonSessionCommands {
            XCTAssertFalse(AgentProcessFinder.isClaudeCodeCLIInvocation(arguments: argv), "\(argv)")
        }
    }

    func testUnreadableArgvCountsAsTheCLI() {
        XCTAssertTrue(AgentProcessFinder.isClaudeCodeCLIInvocation(arguments: []))
    }

    // MARK: - Discovery (and the CWD fallback, which scans the same pids)

    func testDiscoveryFindsOnlyTheCLIAmongTheProcessesRunningTheBinary() {
        var table: [pid_t: (path: String, argv: [String]?)] = [:]
        var expected: [pid_t] = []
        var next: pid_t = 1000
        for argv in cliInvocations {
            table[next] = (binary, argv)
            expected.append(next)
            next += 1
        }
        for argv in nonCLIInvocations {
            table[next] = (binary, argv)
            next += 1
        }
        // An argv that can't be read stays a session's, as before.
        table[next] = (binary, nil)
        expected.append(next)
        next += 1
        // Not Claude Code's binary at all.
        table[next] = ("/usr/bin/grep", ["grep", "-r", "<pattern>"])

        let found = AgentProcessFinder.findClaudePids(
            candidatePids: table.keys.sorted(),
            executablePath: { table[$0]?.path },
            arguments: { table[$0]?.argv }
        )
        XCTAssertEqual(found.sorted(), expected.sorted())
    }

    // MARK: - The orphan sweep

    private func claudeSession() -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/u/project"
        return session
    }

    func testOrphanSweepNeverTerminatesAProcessRunningTheBinaryAsAnythingButTheCLI() {
        let codexSession: SessionSnapshot = {
            var session = SessionSnapshot()
            session.source = "codex"
            return session
        }()
        for argv in nonCLIInvocations {
            for session in [claudeSession(), codexSession, nil] as [SessionSnapshot?] {
                XCTAssertFalse(
                    AppState.shouldTerminateOrphanedProcess(
                        session: session, pid: 4242,
                        executablePath: { _ in self.binary }, arguments: { _ in argv }
                    ),
                    "\(argv) watched for \(session?.source ?? "a card that is gone")"
                )
            }
        }
    }

    func testOrphanSweepStillTerminatesAnOrphanedCLI() {
        for argv in cliInvocations {
            XCTAssertTrue(
                AppState.shouldTerminateOrphanedProcess(
                    session: claudeSession(), pid: 4242,
                    executablePath: { _ in self.binary }, arguments: { _ in argv }
                ),
                "\(argv)"
            )
        }
    }

    // MARK: - A real process tree: the session's CLI running a grep as `ugrep`

    /// `<root>/bin/claude` (the package's golden stub, standing in for Claude
    /// Code's binary) whose child is the same file run through a symlink named
    /// `ugrep`, as `exec -a ugrep` does: argv[0] says `ugrep`, the executable
    /// is still `claude`. The child runs `sleep`.
    private struct ClaudeRunningGrep {
        let cli: pid_t
        let tool: pid_t
        let sleeper: pid_t?
        let root: URL
    }

    private func startClaudeRunningGrep() async throws -> ClaudeRunningGrep {
        let stub = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("codeisland-golden-stub")
        guard FileManager.default.isExecutableFile(atPath: stub.path) else {
            throw XCTSkip("codeisland-golden-stub is not built next to the tests (swift build --build-tests)")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tool-tree-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let tools = root.appendingPathComponent("tools")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try fm.copyItem(at: stub, to: claude)
        let ugrep = tools.appendingPathComponent("ugrep")
        try fm.createSymbolicLink(at: ugrep, withDestinationURL: claude)

        let cli = Process()
        cli.executableURL = claude
        cli.arguments = ["--", ugrep.path, "--", "/bin/sleep", "20"]
        try cli.run()
        let cliPid = cli.processIdentifier

        var toolPid: pid_t?
        await waitUntil("the stub's ugrep child started") {
            toolPid = ProcessTable.allProcessIds().first { pid in
                ProcessTable.parentPid(of: pid) == cliPid
                    && ProcessTable.getProcessArgs(pid)?.first.map { ($0 as NSString).lastPathComponent } == "ugrep"
            }
            return toolPid != nil
        }
        guard let toolPid else {
            kill(cliPid, SIGKILL)
            throw XCTSkip("the process tree did not start")
        }
        var sleeper: pid_t?
        await waitUntil("the ugrep child's sleep started") {
            sleeper = ProcessTable.allProcessIds().first { ProcessTable.parentPid(of: $0) == toolPid }
            return sleeper != nil
        }
        return ClaudeRunningGrep(cli: cliPid, tool: toolPid, sleeper: sleeper, root: root)
    }

    /// Only ever the three processes the test started.
    private func stop(_ tree: ClaudeRunningGrep) {
        if let sleeper = tree.sleeper { kill(sleeper, SIGKILL) }
        kill(tree.tool, SIGKILL)
        kill(tree.cli, SIGKILL)
        try? FileManager.default.removeItem(at: tree.root)
    }

    func testTheProcessATrackedToolStandsForIsTheSessionThatRanIt() async throws {
        let tree = try await startClaudeRunningGrep()
        defer { stop(tree) }
        XCTAssertTrue(
            ProcessTable.executablePath(for: tree.tool)?.hasSuffix("/bin/claude") ?? false,
            "the tool runs the claude executable"
        )
        XCTAssertEqual(ProcessTable.trackedProcessIdentity(for: tree.tool, source: "claude")?.pid, tree.cli)
        XCTAssertEqual(ProcessTable.trackedProcessIdentity(for: tree.cli, source: "claude")?.pid, tree.cli)
    }

    func testOrphanSweepLeavesARealToolProcessAlone() async throws {
        let tree = try await startClaudeRunningGrep()
        defer { stop(tree) }
        XCTAssertFalse(AppState.shouldTerminateOrphanedProcess(session: claudeSession(), pid: tree.tool))
        XCTAssertTrue(AppState.shouldTerminateOrphanedProcess(session: claudeSession(), pid: tree.cli))
    }

    /// A hook whose `_ppid` names the tool: the card watches the CLI.
    @MainActor
    func testAHookNamingAToolWatchesTheSessionThatRanIt() async throws {
        let tree = try await startClaudeRunningGrep()
        defer { stop(tree) }
        let appState = AppState()
        let payload: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "claude-tool-hook",
            "cwd": tree.root.path,
            "prompt": "<prompt>",
            "_source": "claude",
            "_ppid": Int(tree.tool),
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        appState.handleEvent(event)
        XCTAssertEqual(appState.sessions["claude-tool-hook"]?.cliPid, tree.cli)
    }

    /// A discovery that found the tool: the card watches the CLI.
    @MainActor
    func testADiscoveryOfAToolWatchesTheSessionThatRanIt() async throws {
        let tree = try await startClaudeRunningGrep()
        defer { stop(tree) }
        let appState = AppState()
        appState.integrateDiscovered([
            DiscoveredSession(
                sessionId: "claude-tool-discovery",
                cwd: tree.root.path,
                tty: nil,
                model: nil,
                pid: tree.tool,
                modifiedAt: Date(),
                recentMessages: []
            ),
        ])
        XCTAssertEqual(appState.sessions["claude-tool-discovery"]?.cliPid, tree.cli)
    }
}
