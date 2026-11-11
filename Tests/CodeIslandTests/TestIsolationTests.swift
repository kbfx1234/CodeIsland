import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// A test process must not act on the machine it runs on: no AppleScript to the
/// user's terminal, no answers read off their desktop, no writes to their
/// `~/.codeisland/sessions.json`.
final class TestIsolationTests: XCTestCase {

    // MARK: - Defaults in a test process

    func testThisProcessIsRecognisedAsATestRun() {
        XCTAssertTrue(RuntimeEnvironment.isRunningTests)
    }

    func testAppleScriptGoesNowhereUnlessATestInstallsARunner() {
        XCTAssertNil(
            AppleScriptRunner.current.evaluate("return \"ran\"", 5),
            "the default runner in a test process must not execute scripts"
        )
    }

    func testVisibilityProbeCannotSeeTheRealDesktop() throws {
        // The app really in front right now, modelled as a session's terminal.
        guard let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            throw XCTSkip("no frontmost app to compare against (headless session)")
        }
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        session.termBundleId = frontBundleId

        XCTAssertFalse(TerminalVisibilityDetector.isTerminalFrontmostForSession(session))
        XCTAssertFalse(TerminalVisibilityDetector.isSessionTabVisible(session))
    }

    func testInstalledProbeIsWhatCallersSeeAndIsRemovedAfterTheTest() {
        var ghostty = SessionSnapshot()
        ghostty.termBundleId = "com.mitchellh.ghostty"
        var iterm = SessionSnapshot()
        iterm.termBundleId = "com.googlecode.iterm2"

        installVisibilityProbe(.terminalInFront { $0.termBundleId == "com.mitchellh.ghostty" })

        XCTAssertTrue(TerminalVisibilityDetector.isTerminalFrontmostForSession(ghostty))
        XCTAssertTrue(TerminalVisibilityDetector.isSessionTabVisible(ghostty))
        XCTAssertFalse(TerminalVisibilityDetector.isTerminalFrontmostForSession(iterm))
    }

    @MainActor
    func testDiscoveryScansNoRealProcessesOrSessionStores() {
        // An AppState's discovery gets the inert scanners in a test process.
        let scanners = AppState().discovery.scanners
        XCTAssertEqual(scanners.sessions().count, 0)
        XCTAssertEqual(scanners.codexDesktopSessions().count, 0)
        XCTAssertEqual(scanners.watchRoots(), [], "no watcher on the real session stores")
    }

    @MainActor
    func testAppStateReadsNoRealSessionStores() {
        // Nor does it read the agents' stores for its cards.
        let readers = AppState().storeReaders
        var card = SessionSnapshot()
        card.cwd = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertNil(readers.title(ProviderTitleLookup(sessionId: "s", provider: "claude", cwd: card.cwd)))
        XCTAssertNil(readers.model("s", card))
        XCTAssertNil(readers.nativeAppFinishedTurn("s", card))
        XCTAssertFalse(readers.cursorYoloMode())
    }

    func testHookInstallsNeverStartTheUsersClaude() {
        // Installing Claude Code hooks asks for its version, which the app
        // gets by running `claude --version`.
        XCTAssertNil(ConfigInstaller.claudeVersionProvider())
    }

    // MARK: - Isolated runs

    func testIsolatedRunsAreAskedForExplicitly() {
        XCTAssertTrue(RuntimeEnvironment.isIsolated(["CODEISLAND_ISOLATED": "1"]))
        XCTAssertFalse(RuntimeEnvironment.isIsolated([:]))
        XCTAssertFalse(RuntimeEnvironment.isIsolated(["CODEISLAND_ISOLATED": "0"]))
        XCTAssertFalse(RuntimeEnvironment.isIsolated(["CODEISLAND_ISOLATED": ""]))
    }

    /// Without a socket of its own, an isolated island would answer every
    /// hook on this Mac in place of the installed app: it quits instead.
    func testAnIsolatedRunNeedsASocketOfItsOwn() {
        XCTAssertNotNil(RuntimeEnvironment.isolationProblem(["CODEISLAND_ISOLATED": "1"]))
        XCTAssertNotNil(RuntimeEnvironment.isolationProblem(["CODEISLAND_ISOLATED": "1", "CODEISLAND_SOCKET_PATH": "  "]))
        XCTAssertNil(RuntimeEnvironment.isolationProblem(["CODEISLAND_ISOLATED": "1", "CODEISLAND_SOCKET_PATH": "/tmp/dev.sock"]))
        XCTAssertNil(RuntimeEnvironment.isolationProblem(["CODEISLAND_SOCKET_PATH": ""]), "a normal launch is never refused")
    }

    // MARK: - Session persistence location

    func testExplicitDirectoryOverrideWins() {
        XCTAssertEqual(
            SessionPersistence.directory(
                environment: ["CODEISLAND_SESSIONS_DIR": "/tmp/elsewhere"],
                isRunningTests: false,
                home: "/Users/someone"
            ),
            "/tmp/elsewhere"
        )
        XCTAssertEqual(
            SessionPersistence.directory(
                environment: ["CODEISLAND_SESSIONS_DIR": "/tmp/elsewhere"],
                isRunningTests: true,
                home: "/Users/someone"
            ),
            "/tmp/elsewhere"
        )
    }

    func testAppKeepsSessionsInTheHomeFolder() {
        XCTAssertEqual(
            SessionPersistence.directory(environment: [:], isRunningTests: false, home: "/Users/someone"),
            "/Users/someone/.codeisland"
        )
        XCTAssertEqual(
            SessionPersistence.directory(
                environment: ["CODEISLAND_SESSIONS_DIR": ""],
                isRunningTests: false,
                home: "/Users/someone"
            ),
            "/Users/someone/.codeisland",
            "an empty override is no override"
        )
    }

    func testTestProcessKeepsSessionsInItsOwnTempFolder() {
        let dir = SessionPersistence.directory(environment: [:], isRunningTests: true, home: "/Users/someone")
        XCTAssertTrue(dir.hasPrefix(NSTemporaryDirectory()), dir)
        XCTAssertTrue(dir.hasSuffix("-\(getpid())"), "one folder per test process: \(dir)")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertNotEqual(SessionPersistence.dirPath, home + "/.codeisland")
        XCTAssertFalse(SessionPersistence.dirPath.hasPrefix(home + "/."), SessionPersistence.dirPath)
    }

    func testSaveAndClearTouchOnlyTheTestFolder() throws {
        let file = SessionPersistence.dirPath + "/sessions.json"
        var session = SessionSnapshot()
        session.cwd = "/tmp/isolation"
        SessionPersistence.save(["isolation-check": session])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        XCTAssertEqual(SessionPersistence.load().map(\.sessionId), ["isolation-check"])

        SessionPersistence.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }
}
