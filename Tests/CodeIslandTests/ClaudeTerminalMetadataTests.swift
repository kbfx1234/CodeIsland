import XCTest
import Darwin
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class ClaudeTerminalMetadataTests: XCTestCase {
    private let env = ["TERM_PROGRAM": "tmux", "__CFBundleIdentifier": "com.mitchellh.ghostty",
                       "TMUX": "/tmp/tmux-test/default,123,0", "TMUX_PANE": "%13"]

    private func fixture() throws -> (AppState, ProcessIdentity) {
        let state = AppState()
        let process = try XCTUnwrap(ProcessTable.liveProcessIdentity(for: getpid()))
        var session = SessionSnapshot()
        session.source = "claude"
        session.cliPid = process.pid
        session.cliStartTime = process.startTime
        state.sessions["claude-test"] = session
        return (state, process)
    }

    func testDiscoveredClaudeRecoversGhosttyAndTmuxMetadata() throws {
        let (state, process) = try fixture()
        XCTAssertTrue(state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: process,
            readEnvironment: { pid in XCTAssertEqual(pid, process.pid); return self.env }))
        let session = try XCTUnwrap(state.sessions["claude-test"])
        XCTAssertEqual(session.termApp, "tmux")
        XCTAssertEqual(session.termBundleId, "com.mitchellh.ghostty")
        XCTAssertEqual(session.tmuxPane, "%13")
        XCTAssertEqual(session.tmuxEnv, env["TMUX"])
    }

    func testExistingHookMetadataIsPreserved() throws {
        let (state, process) = try fixture()
        state.sessions["claude-test"]?.tmuxPane = "%19"
        state.sessions["claude-test"]?.tmuxEnv = "/different/socket,1,0"
        _ = state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: process,
            readEnvironment: { _ in self.env })
        XCTAssertEqual(state.sessions["claude-test"]?.tmuxPane, "%19")
        XCTAssertEqual(state.sessions["claude-test"]?.tmuxEnv, "/different/socket,1,0")
    }

    func testDifferentOrReusedProcessCannotWriteMetadata() throws {
        let (state, process) = try fixture()
        state.sessions["claude-test"]?.cliPid = process.pid + 1
        XCTAssertFalse(state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: process,
            readEnvironment: { _ in XCTFail("Must not read unrelated process"); return self.env }))
        state.sessions["claude-test"]?.cliPid = process.pid
        let stale = ProcessIdentity(pid: process.pid, startTime: Date(timeIntervalSince1970: 1))
        state.sessions["claude-test"]?.cliStartTime = stale.startTime
        XCTAssertFalse(state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: stale,
            readEnvironment: { _ in XCTFail("Must not read reused process"); return self.env }))
    }

    func testRemoteDesktopAndCodexSessionsAreNotReclassified() throws {
        for mode in ["remote", "desktop", "codex"] {
            let (state, process) = try fixture()
            if mode == "remote" { state.sessions["claude-test"]?.remoteHostId = "server" }
            if mode == "desktop" { state.sessions["claude-test"]?.termBundleId = "com.anthropic.claudefordesktop" }
            if mode == "codex" { state.sessions["claude-test"]?.source = "codex" }
            XCTAssertFalse(state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: process,
                readEnvironment: { _ in XCTFail("Unexpected environment probe: \(mode)"); return self.env }))
        }
    }
    /// tryMonitorSession runs on every hook event and discovery scan; a session
    /// outside tmux (most of them) must not re-read its process every time.
    func testEnvironmentIsReadOncePerProcess() throws {
        let (state, process) = try fixture()
        var reads = 0
        let withoutTmux = ["TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.mitchellh.ghostty"]
        for _ in 0..<5 {
            XCTAssertFalse(state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: process,
                readEnvironment: { _ in reads += 1; return withoutTmux }))
        }
        XCTAssertEqual(reads, 1)
        XCTAssertNil(state.sessions["claude-test"]?.termApp, "Only a tmux process is backfilled")

        // A removed and re-created card reads again.
        state.removeSession("claude-test")
        state.sessions["claude-test"] = try fixture().0.sessions["claude-test"]
        _ = state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: process,
            readEnvironment: { _ in reads += 1; return self.env })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(state.sessions["claude-test"]?.tmuxPane, "%13")
    }

    func testUnreadableEnvironmentDoesNotInventTerminalMetadata() throws {
        let (state, process) = try fixture()
        XCTAssertFalse(state.backfillClaudeTerminalMetadata(sessionId: "claude-test", process: process,
            readEnvironment: { _ in nil }))
        XCTAssertNil(state.sessions["claude-test"]?.tmuxPane)
        XCTAssertNil(state.sessions["claude-test"]?.termBundleId)
    }
}
