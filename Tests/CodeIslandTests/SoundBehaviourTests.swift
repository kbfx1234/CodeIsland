import XCTest
@testable import CodeIsland
import CodeIslandCore

/// What sound a hook event produces is a decision of its own — not the same
/// question as "should a card open" — and until #312 nothing in the app could
/// assert it. These are the cases that were previously only readable, not
/// checkable.
@MainActor
final class SoundBehaviourTests: XCTestCase {
    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundApprovalNeeded,
        SettingsKey.soundSessionStart,
        SettingsKey.quietHoursEnabled,
        SettingsKey.quietHoursStart,
        SettingsKey.quietHoursEnd,
        SettingsKey.smartSuppress,
        SettingsKey.autoExpandOnPermission,
        SettingsKey.soundBoot,
    ]

    override func setUp() {
        super.setUp()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundApprovalNeeded)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
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

    // MARK: - The burst rule

    /// The approval chime marks the *start* of a burst. Three approvals queued
    /// back to back are one interruption, not three chimes.
    func testABurstOfQueuedApprovalsChimesOnce() async throws {
        let appState = AppState()
        var tasks: [Task<Data, Never>] = []
        for index in 0..<3 {
            let event = try makePermissionEvent(sessionId: "burst-\(index)")
            tasks.append(await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) })
        }

        XCTAssertEqual(appState.permissionQueue.count, 3)
        XCTAssertEqual(played, ["8bit_approval"], "one burst, one chime")

        for index in 0..<3 { appState.handlePeerDisconnect(sessionId: "burst-\(index)") }
        for task in tasks { _ = try await awaitValue(of: task) }
    }

    /// #309's regression, now expressible: a dismissed request stays queued, and
    /// must not make the next session's approval arrive in silence.
    func testDismissedRequestDoesNotSwallowTheNextSessionsChime() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "snd-dismissed")
        let firstTask = await startHookRequest { appState.handlePermissionRequest(first, continuation: $0) }
        XCTAssertEqual(played, ["8bit_approval"])

        appState.dismissPermissionPrompt()
        played = []

        let second = try makePermissionEvent(sessionId: "snd-later")
        let secondTask = await startHookRequest { appState.handlePermissionRequest(second, continuation: $0) }

        XCTAssertEqual(
            played,
            ["8bit_approval"],
            "the dismissed request is hidden, not in progress — the new one still announces itself"
        )

        appState.handlePeerDisconnect(sessionId: "snd-dismissed")
        appState.handlePeerDisconnect(sessionId: "snd-later")
        _ = try await awaitValue(of: firstTask)
        _ = try await awaitValue(of: secondTask)
    }

    /// A card that never opens still chimes: with auto-expand off the sound is
    /// the *only* signal the user gets. (#292)
    func testAutoExpandOffStillChimes() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        let appState = AppState()
        let event = try makePermissionEvent(sessionId: "snd-collapsed")
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(played, ["8bit_approval"])

        appState.handlePeerDisconnect(sessionId: "snd-collapsed")
        _ = try await awaitValue(of: task)
    }

    // MARK: - Gates

    func testMasterToggleOffSilencesEverything() {
        UserDefaults.standard.set(false, forKey: SettingsKey.soundEnabled)
        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, [])
    }

    func testPerEventToggleOffSilencesOnlyThatEvent() {
        UserDefaults.standard.set(false, forKey: SettingsKey.soundApprovalNeeded)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundSessionStart)

        SoundManager.shared.handleEvent("PermissionRequest")
        SoundManager.shared.handleEvent("SessionStart")

        XCTAssertEqual(played, ["8bit_start"])
    }

    func testQuietHoursSilenceEventSounds() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        UserDefaults.standard.set(true, forKey: SettingsKey.quietHoursEnabled)
        // A window that certainly contains "now", written so it never spans midnight.
        UserDefaults.standard.set(0, forKey: SettingsKey.quietHoursStart)
        UserDefaults.standard.set(min(now + 1, 24 * 60), forKey: SettingsKey.quietHoursEnd)

        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, [])
    }

    func testUnknownEventNameProducesNoSound() {
        SoundManager.shared.handleEvent("SomethingElse")
        XCTAssertEqual(played, [])
    }

    /// The launch chime answers to its own switch, and a hook event that
    /// happens to carry the launch cue's name rings nothing.
    func testOnlyTheLaunchRingsTheLaunchChime() throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.soundBoot)
        let appState = AppState()
        appState.handleEvent(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": SoundCue.launch, "session_id": "snd-launch-named-hook",
        ]))))
        XCTAssertEqual(played, [])

        SoundManager.shared.playBoot()
        XCTAssertEqual(played, ["8bit_boot"])

        UserDefaults.standard.set(false, forKey: SettingsKey.soundBoot)
        SoundManager.shared.playBoot()
        XCTAssertEqual(played, ["8bit_boot"])
    }

    // MARK: - Helpers

    private func makePermissionEvent(sessionId: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": ["command": "echo hi"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
