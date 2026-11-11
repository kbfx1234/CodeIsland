import XCTest
@testable import CodeIsland

/// The contract the jump and visibility paths rely on now that their scripts
/// run in `/usr/bin/osascript` instead of NSAppleScript.
///
/// These scripts only compute a value; none of them addresses an application,
/// so running them sends no Apple Event anywhere.
final class AppleScriptRunnerTests: XCTestCase {
    func testResultComesBackAsText() {
        // Callers compare the trimmed result with "true", as they did with
        // NSAppleScript's stringValue; osascript prints strings unquoted.
        let result = AppleScriptRunner.osascript.evaluate("return \"true\"", 10)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    func testNonASCIISurvivesTheRoundTrip() {
        // Folder names and tab titles are interpolated into the scripts, and
        // the app's environment has no locale to lean on.
        let script = """
        set title to "项目-é"
        if title contains "项目" then return title
        return "no match"
        """
        let result = AppleScriptRunner.osascript.evaluate(script, 10)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "项目-é")
    }

    func testFailingScriptIsNil() {
        XCTAssertNil(AppleScriptRunner.osascript.evaluate("error \"boom\"", 10))
    }

    func testScriptThatOutlivesItsTimeoutIsNil() {
        let started = Date()
        XCTAssertNil(AppleScriptRunner.osascript.evaluate("delay 20\nreturn \"late\"", 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the timeout must end the wait")
    }
}
