import XCTest
@testable import CodeIslandCore

final class SceneMuteStateTests: XCTestCase {
    func testLockMutesAndUnlockRestores() {
        var state = SceneMuteState()
        XCTAssertFalse(state.isQuiet)
        XCTAssertTrue(state.apply(.screenLocked))
        XCTAssertTrue(state.isQuiet)
        XCTAssertTrue(state.apply(.screenUnlocked))
        XCTAssertFalse(state.isQuiet)
    }

    func testScreensaverMutes() {
        var state = SceneMuteState()
        XCTAssertTrue(state.apply(.screensaverStarted))
        XCTAssertTrue(state.isQuiet)
        XCTAssertTrue(state.apply(.screensaverStopped))
        XCTAssertFalse(state.isQuiet)
    }

    /// A display that only went to sleep is tracked (pushes count it as
    /// away) but does not mute: its owner is often nearby, waiting.
    func testDisplaySleepAloneIsTrackedButDoesNotMute() {
        var state = SceneMuteState()
        XCTAssertFalse(state.apply(.displaysSlept), "no edge for the quiet scene")
        XCTAssertTrue(state.displaysAsleep)
        XCTAssertFalse(state.isQuiet)
        XCTAssertFalse(state.apply(.displaysWoke))
        XCTAssertFalse(state.displaysAsleep)
    }

    /// The usual away sequence: screen saver → it locks → displays sleep. The
    /// first "end" to arrive must not unmute while the others still hold.
    func testOverlappingStatesStayQuietUntilTheLastOneEnds() {
        var state = SceneMuteState()
        state.apply(.screensaverStarted)
        state.apply(.screenLocked)
        state.apply(.displaysSlept)

        XCTAssertFalse(state.apply(.displaysWoke), "still locked, still quiet")
        XCTAssertFalse(state.apply(.screensaverStopped), "still locked, still quiet")
        XCTAssertTrue(state.isQuiet)
        XCTAssertTrue(state.apply(.screenUnlocked))
        XCTAssertFalse(state.isQuiet)
    }

    /// Unlock needs a person at an awake screen, so it also clears a screen
    /// saver / display flag whose "end" notification went missing.
    func testUnlockClearsStaleFlags() {
        var state = SceneMuteState()
        state.apply(.screensaverStarted)
        state.apply(.displaysSlept)
        state.apply(.screenLocked)
        state.apply(.screenUnlocked)
        XCTAssertFalse(state.isQuiet)
        XCTAssertFalse(state.screensaverRunning)
        XCTAssertFalse(state.displaysAsleep)
    }

    func testRepeatedSignalReportsNoChange() {
        var state = SceneMuteState()
        XCTAssertTrue(state.apply(.screenLocked))
        XCTAssertFalse(state.apply(.screenLocked))
        XCTAssertFalse(state.apply(.screensaverStarted), "already quiet")
    }
}
