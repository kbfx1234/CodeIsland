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

    func testDiscoveryScansNoRealProcessesOrSessionStores() {
        XCTAssertEqual(AppState.discoveryScanner().count, 0)
    }

    @MainActor
    func testAutomaticKiroRefreshDoesNotReadTheUsersSessionStore() async {
        let previous = UserDefaults.standard.object(forKey: SettingsKey.showUsageStats)
        UserDefaults.standard.set(true, forKey: SettingsKey.showUsageStats)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SettingsKey.showUsageStats)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.showUsageStats)
            }
        }
        let state = AppState()
        state.refreshKiroUsageIfStale()
        await Task.yield()
        XCTAssertNil(state.kiroUsage)
    }

    func testHookInstallsNeverStartTheUsersClaude() {
        // Installing Claude Code hooks asks for its version, which the app
        // gets by running `claude --version`.
        XCTAssertNil(ConfigInstaller.claudeVersionProvider())
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
