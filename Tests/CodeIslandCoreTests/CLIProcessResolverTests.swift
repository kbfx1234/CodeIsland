import XCTest
@testable import CodeIslandCore

final class CLIProcessResolverTests: XCTestCase {

    // MARK: - resolvedSessionPID

    /// #148 core repro: Cursor IDE spawns N sub-agent processes, each runs
    /// its own hook subprocess with a different immediate ppid. All those
    /// sub-agents share the same root Cursor binary in their ancestry, so
    /// `resolvedSessionPID` must collapse them onto the same PID.
    func testParallelSubAgentsCollapseToRootSourcePID() {
        // Sub-agent #1 ancestry: hook → sub-agent A (12345) → cursor-agent main (5000)
        let subA: [(pid: Int32, executablePath: String?)] = [
            (12345, "/Users/u/.cursor/agent/sub-agent"),
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        // Sub-agent #2 ancestry: hook → sub-agent B (67890) → cursor-agent main (5000)
        let subB: [(pid: Int32, executablePath: String?)] = [
            (67890, "/Users/u/.cursor/agent/sub-agent"),
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]

        let pidA = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: subA
        )
        let pidB = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 67890, source: "cursor-cli", ancestry: subB
        )

        XCTAssertEqual(pidA, 5000)
        XCTAssertEqual(pidB, 5000, "Different sub-agent ppids must resolve to the same root cursor-agent PID for session grouping (#148)")
    }

    /// When multiple binaries of the same source appear in the ancestry,
    /// pick the *root-most* (last) one. Distinguishes resolvedSessionPID
    /// from resolvedTrackedPID, which picks the nearest (first).
    func testResolvedSessionPIDPicksRootMostMatch() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (1001, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),  // nearest
            (2002, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),  // intermediate
            (3003, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),  // root-most
        ]
        let session = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 1001, source: "cursor-cli", ancestry: ancestry
        )
        let tracked = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 1001, source: "cursor-cli", ancestry: ancestry
        )
        XCTAssertEqual(session, 3003, "session pid is the root-most matching binary")
        XCTAssertEqual(tracked, 1001, "tracked pid stays the nearest matching binary")
    }

    /// No binary in the ancestry matches the declared source — fall back
    /// to the immediate ppid (preserves prior behavior for everything but
    /// sub-agent CLIs).
    func testResolvedSessionPIDFallsBackToImmediateParentWhenNoMatch() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (12345, "/bin/sh"),
            (5000, "/usr/bin/login"),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: ancestry
        )
        XCTAssertEqual(pid, 12345)
    }

    /// Empty ancestry (e.g. proc lookup failed) — fall back to immediate ppid.
    func testResolvedSessionPIDFallsBackOnEmptyAncestry() {
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: []
        )
        XCTAssertEqual(pid, 12345)
    }

    /// nil source — nothing to match against, so return immediate ppid.
    func testResolvedSessionPIDFallsBackOnNilSource() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (12345, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: nil, ancestry: ancestry
        )
        XCTAssertEqual(pid, 12345)
    }

    // MARK: - fallbackSessionPID (GUI host ghost cards)

    /// Real repro: a `--source kiro` event with no session_id. Kiro is an
    /// Electron IDE, so the loose `/<source>` rule matches its GUI binary, and
    /// `ancestry.last` deliberately picks the root-most one — which is the app's
    /// main process (ppid 1, alive across every window and workspace). Keying a
    /// session on that PID produced one global ghost card that every
    /// session-id-less Kiro event landed on, sitting beside the real cards.
    func testFallbackSessionPIDRefusesGUIHostAncestry() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (69036, "/Applications/Kiro.app/Contents/Frameworks/Kiro Helper (Plugin).app/Contents/MacOS/Kiro Helper (Plugin)"),
            (2360, "/Applications/Kiro.app/Contents/MacOS/Kiro"),
        ]
        XCTAssertNil(
            CLIProcessResolver.fallbackSessionPID(
                immediateParentPID: 69036, source: "kiro", ancestry: ancestry
            ),
            "A GUI host PID cannot identify a session — the event must be dropped"
        )
    }

    /// Refusing must not degrade to the immediate parent: that mints a fresh id
    /// per invoking shell, trading one persistent ghost for an endless trickle
    /// of orphans.
    func testFallbackSessionPIDDoesNotDegradeToShellForGUIHost() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (99999, "/bin/zsh"),
            (2861, "/Applications/Kiro.app/Contents/Frameworks/Kiro Helper.app/Contents/MacOS/Kiro Helper"),
            (2360, "/Applications/Kiro.app/Contents/MacOS/Kiro"),
        ]
        XCTAssertNil(CLIProcessResolver.fallbackSessionPID(
            immediateParentPID: 99999, source: "kiro", ancestry: ancestry
        ))
    }

    /// #148 must not regress: `cursor-agent` is a real CLI binary (one process
    /// per session), so its PID stays a valid identity even though Cursor is
    /// also a desktop IDE.
    func testFallbackSessionPIDStillCollapsesRealCLISubAgents() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (12345, "/Users/u/.cursor/agent/sub-agent"),
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.fallbackSessionPID(
                immediateParentPID: 12345, source: "cursor-cli", ancestry: ancestry
            ),
            5000
        )
    }

    /// No source match at all — keep the historical degradation to the immediate
    /// parent. Non-IDE CLIs without a stable session id depend on it.
    func testFallbackSessionPIDKeepsImmediateParentWhenNoSourceMatch() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (12345, "/bin/sh"),
            (5000, "/usr/bin/login"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.fallbackSessionPID(
                immediateParentPID: 12345, source: "cursor-cli", ancestry: ancestry
            ),
            12345
        )
    }

    /// A CLI shipped inside an app bundle's Resources (Codex Desktop) is still
    /// one process per session — only MacOS/ and Frameworks/ are GUI hosts.
    func testGUIHostDetectionSpareBundledCLIBinaries() {
        XCTAssertTrue(CLIProcessResolver.isGUIApplicationHostPath(
            "/Applications/Kiro.app/Contents/MacOS/Kiro"))
        XCTAssertTrue(CLIProcessResolver.isGUIApplicationHostPath(
            "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"))

        XCTAssertFalse(CLIProcessResolver.isGUIApplicationHostPath(
            "/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertFalse(CLIProcessResolver.isGUIApplicationHostPath(
            "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"))
        XCTAssertFalse(CLIProcessResolver.isGUIApplicationHostPath("/bin/zsh"))
        XCTAssertFalse(CLIProcessResolver.isGUIApplicationHostPath(nil))
    }

    /// Kiro belongs in `ideHostSources`: its helper processes sit in the
    /// ancestry of anything started from its integrated terminal, and the
    /// default `/<source>` rule matches all of them via "/kiro". Without this,
    /// a source-less CLI run from Kiro's terminal is attributed to kiro (#220).
    func testInferSourceIgnoresKiroIDEHostForSourcelessCLI() {
        XCTAssertTrue(SessionSnapshot.ideHostSources.contains("kiro"))

        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (4321, "/opt/homebrew/bin/node"),
            (2861, "/Applications/Kiro.app/Contents/Frameworks/Kiro Helper.app/Contents/MacOS/Kiro Helper"),
            (2360, "/Applications/Kiro.app/Contents/MacOS/Kiro"),
        ]
        XCTAssertNil(CLIProcessResolver.inferSource(ancestry: ancestry))
    }

    // MARK: - inferSource (#220 / #95)

    /// #220: Claude Code launched inside Cursor's integrated terminal fires the
    /// source-less Claude hook. The real `claude` process is a Node binary (its
    /// path does NOT end in `/claude`), while Cursor's GUI host/helper processes
    /// carry `/cursor` in their path. inferSource must NOT greedily attribute the
    /// session to the desktop `cursor` source — it should return nil so the
    /// bridge falls back to the default "claude".
    func testInferSourceIgnoresCursorIDEHostForSourcelessClaude() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            // `claude` is really a Node script; argv0 is node, not .../claude.
            (4321, "/opt/homebrew/bin/node"),
            (4000, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"),
            (3000, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ]
        XCTAssertNil(
            CLIProcessResolver.inferSource(ancestry: ancestry),
            "Cursor's GUI host must not be inferred as the `cursor` source (#220)"
        )
    }

    /// #95 guard: the omo/OpenCode plugin fires the source-less Claude hook from
    /// inside OpenCode. The real `opencode` binary IS in the ancestry, so
    /// inferSource must still recover "opencode" (the original reason this
    /// inference exists). The #220 fix must not regress this.
    func testInferSourceStillRecoversOpenCodeFromAncestry() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (1234, "/bin/sh"),
            (5678, "/Users/u/.opencode/bin/opencode"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.inferSource(ancestry: ancestry),
            "opencode",
            "Source-less Claude hooks fired from inside OpenCode must still resolve to opencode (#95)"
        )
    }

    /// Cursor's CLI agent (`cursor-agent`) is a real CLI and must still be
    /// recovered as `cursor-cli` — only the desktop IDE *host* is excluded.
    func testInferSourceStillRecoversCursorCliAgent() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.inferSource(ancestry: ancestry),
            "cursor-cli"
        )
    }

    // MARK: - resolvedSessionPID

    /// Defensive: invalid (<= 0) immediate ppid is returned unchanged so
    /// callers can still encode it without contortion.
    func testResolvedSessionPIDReturnsImmediateParentWhenZeroOrNegative() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.resolvedSessionPID(immediateParentPID: 0, source: "cursor-cli", ancestry: ancestry),
            0
        )
        XCTAssertEqual(
            CLIProcessResolver.resolvedSessionPID(immediateParentPID: -1, source: "cursor-cli", ancestry: ancestry),
            -1
        )
    }
}
