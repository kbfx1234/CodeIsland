import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Event sounds hold off while nobody is at the screen: locked, screen saver
/// running, displays asleep. Same gate layer as quiet hours.
@MainActor
final class AwayMuteSoundTests: XCTestCase {
    private var played: [String] = []
    private var quietChanges: [Bool] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundApprovalNeeded,
        SettingsKey.soundBoot,
        SettingsKey.quietHoursEnabled,
        SettingsKey.autoMuteWhenAway,
    ]

    override func setUp() {
        super.setUp()
        played = []
        quietChanges = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in self?.played.append(name) }
        SceneMuteMonitor.shared.resetForTesting()
        SceneMuteMonitor.shared.onQuietChanged = { [weak self] quiet in self?.quietChanges.append(quiet) }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundApprovalNeeded)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundBoot)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.removeObject(forKey: SettingsKey.autoMuteWhenAway)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        SceneMuteMonitor.shared.resetForTesting()
        SceneMuteMonitor.shared.onQuietChanged = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    func testLockedScreenSilencesEventSoundsByDefault() {
        SceneMuteMonitor.shared.apply(.screenLocked)
        SoundManager.shared.handleEvent("PermissionRequest")
        SoundManager.shared.playBoot()
        XCTAssertEqual(played, [])
        XCTAssertTrue(SoundManager.shared.isEventSoundDeferred)
    }

    func testUnlockRestoresSounds() {
        SceneMuteMonitor.shared.apply(.screenLocked)
        SceneMuteMonitor.shared.apply(.screenUnlocked)
        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, ["8bit_approval"])
        XCTAssertFalse(SoundManager.shared.isEventSoundDeferred)
    }

    func testScreensaverAlsoSilences() {
        SceneMuteMonitor.shared.apply(.screensaverStarted)
        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, [])
        XCTAssertTrue(SoundManager.shared.isEventSoundDeferred)
    }

    /// Displays asleep, screen not locked: the person is often right there
    /// waiting on the agent, so sounds (and follow-up reminders) keep coming.
    func testDisplaySleepAloneKeepsSounds() {
        SceneMuteMonitor.shared.apply(.displaysSlept)
        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, ["8bit_approval"])
        XCTAssertFalse(SoundManager.shared.isEventSoundDeferred)
        XCTAssertTrue(SceneMuteMonitor.shared.state.displaysAsleep, "still known to the push away check")
    }

    func testTurningTheSettingOffKeepsSoundsWhileLocked() {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoMuteWhenAway)
        SceneMuteMonitor.shared.apply(.screenLocked)
        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, ["8bit_approval"])
        XCTAssertFalse(SoundManager.shared.isEventSoundDeferred)
    }

    func testMonitorReportsOnlyEdges() {
        SceneMuteMonitor.shared.apply(.screensaverStarted)
        SceneMuteMonitor.shared.apply(.screenLocked)
        SceneMuteMonitor.shared.apply(.screensaverStopped)
        SceneMuteMonitor.shared.apply(.screenUnlocked)
        XCTAssertEqual(quietChanges, [true, false])
    }
}
