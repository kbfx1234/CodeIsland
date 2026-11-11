import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// The monitor's lock state defers to the login session's own flag, so a
/// lock notification that never arrived (coalesced while the app was
/// inactive, or a launch behind the lock screen) cannot leave it wrong.
@MainActor
final class SceneMuteMonitorTests: XCTestCase {
    private var quietChanges: [Bool] = []
    private let monitor = SceneMuteMonitor.shared

    override func setUp() {
        super.setUp()
        quietChanges = []
        monitor.resetForTesting()
        monitor.onQuietChanged = { [weak self] quiet in self?.quietChanges.append(quiet) }
    }

    override func tearDown() {
        monitor.resetForTesting()
        monitor.onQuietChanged = nil
        super.tearDown()
    }

    /// Launched while locked: no notification ever says so, the session does.
    func testLockReadFromTheSessionWithoutANotification() async {
        monitor.lockProbe = { true }
        XCTAssertTrue(monitor.isQuietScene)
        XCTAssertTrue(monitor.state.screenLocked)
        XCTAssertEqual(quietChanges, [], "never re-entrantly, inside the reader")
        await waitUntil("the lock edge was never announced") { self.quietChanges == [true] }
    }

    /// The unlock notification went missing: the session says unlocked, and
    /// the "back" edge still fires so held-back reminders catch up.
    func testMissedUnlockIsCorrectedWithItsEdge() async {
        monitor.apply(.screensaverStarted)
        monitor.apply(.screenLocked)
        monitor.lockProbe = { false }
        XCTAssertFalse(monitor.isQuietScene)
        XCTAssertFalse(monitor.state.screensaverRunning, "unlock clears what it always clears")
        await waitUntil("the unlock edge was never announced") { self.quietChanges == [true, false] }
    }

    func testUnreadableSessionTrustsTheNotifications() {
        monitor.lockProbe = { nil }
        monitor.apply(.screenLocked)
        XCTAssertTrue(monitor.isQuietScene)
        monitor.apply(.screenUnlocked)
        XCTAssertFalse(monitor.isQuietScene)
    }

    func testSessionDictionaryParsing() {
        XCTAssertNil(SceneMuteMonitor.screenLocked(fromSession: nil))
        XCTAssertEqual(SceneMuteMonitor.screenLocked(fromSession: [:]), false)
        XCTAssertEqual(SceneMuteMonitor.screenLocked(fromSession: ["CGSSessionScreenIsLocked": 1]), true)
        XCTAssertEqual(SceneMuteMonitor.screenLocked(fromSession: ["CGSSessionScreenIsLocked": true]), true)
        XCTAssertEqual(
            SceneMuteMonitor.screenLocked(fromSession: ["kCGSSessionOnConsoleKey": false]), true,
            "another user holds the console: this one is not at the screen"
        )
        XCTAssertEqual(SceneMuteMonitor.screenLocked(fromSession: ["kCGSSessionOnConsoleKey": 1]), false)
    }

    /// Fast user switching maps onto lock / unlock; displays only feed the
    /// push "away" check.
    func testObservedSignals() {
        let workspace = Dictionary(uniqueKeysWithValues: SceneMuteMonitor.workspaceSignals.map { ($0.0, $0.1) })
        XCTAssertEqual(workspace[NSWorkspace.sessionDidResignActiveNotification], .screenLocked)
        XCTAssertEqual(workspace[NSWorkspace.sessionDidBecomeActiveNotification], .screenUnlocked)
        XCTAssertEqual(workspace[NSWorkspace.screensDidSleepNotification], .displaysSlept)
        XCTAssertEqual(SceneMuteMonitor.distributedSignals["com.apple.screenIsLocked"], .screenLocked)
        XCTAssertEqual(SceneMuteMonitor.distributedSignals["com.apple.screenIsUnlocked"], .screenUnlocked)
    }

    /// The push presence check reads the same authoritative lock.
    func testPushPresenceSeesTheSessionLock() {
        monitor.lockProbe = { true }
        XCTAssertTrue(PushPresence.current().screenLocked)
    }
}
