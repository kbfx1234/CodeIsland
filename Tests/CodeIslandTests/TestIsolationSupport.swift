import XCTest
@testable import CodeIsland
import CodeIslandCore

// Seams that keep tests off the machine they run on. In a test process the
// terminal-visibility probe answers "can't tell" and AppleScript goes nowhere
// (see RuntimeEnvironment); a test that needs another answer installs it here
// for its own duration.

extension XCTestCase {
    /// Uses `probe` for Smart Suppress, follow-ups and jump validation until
    /// this test ends, then puts the previous probe back.
    func installVisibilityProbe(_ probe: TerminalVisibilityDetector.Probe) {
        let saved = TerminalVisibilityDetector.probe
        TerminalVisibilityDetector.probe = probe
        addTeardownBlock { TerminalVisibilityDetector.probe = saved }
    }

    /// Sends the activator's and the detector's AppleScript to `runner` until
    /// this test ends, then puts the previous runner back.
    func installAppleScriptRunner(_ runner: AppleScriptRunner) {
        let saved = AppleScriptRunner.current
        AppleScriptRunner.current = runner
        addTeardownBlock { AppleScriptRunner.current = saved }
    }
}

extension TerminalVisibilityDetector.Probe {
    /// The terminal of every session matching `isInFront` is the frontmost app
    /// with that session's tab showing; no other session's terminal is.
    static func terminalInFront(
        where isInFront: @escaping @Sendable (SessionSnapshot) -> Bool
    ) -> Self {
        Self(isTerminalFrontmost: isInFront, isSessionTabVisible: isInFront)
    }
}
