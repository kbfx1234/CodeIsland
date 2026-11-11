import XCTest
@testable import CodeIsland
import CodeIslandCore

/// AppState asks `AttentionPolicy` about every moment, whatever source it
/// comes from, so one rule holds everywhere at once. These pin that wiring;
/// the rules themselves are AttentionPolicyTests' rows.
@MainActor
final class AttentionWiringTests: XCTestCase {
    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundSessionStart,
        SettingsKey.soundPromptSubmit,
        SettingsKey.soundTaskComplete,
        SettingsKey.soundApprovalNeeded,
        SettingsKey.quietHoursEnabled,
        SettingsKey.autoMuteWhenAway,
        SettingsKey.completionNotificationStyle,
    ]

    override func setUp() {
        super.setUp()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in self?.played.append(name) }
        for key in [
            SettingsKey.soundEnabled, SettingsKey.soundSessionStart, SettingsKey.soundPromptSubmit,
            SettingsKey.soundTaskComplete, SettingsKey.soundApprovalNeeded,
        ] {
            UserDefaults.standard.set(true, forKey: key)
        }
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        // Whatever the test machine's lock screen is doing must not matter.
        UserDefaults.standard.set(false, forKey: SettingsKey.autoMuteWhenAway)
        UserDefaults.standard.set("expand", forKey: SettingsKey.completionNotificationStyle)
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

    /// A child is a child whichever source drives its card: the same rule
    /// that keeps a pi-subagents child quiet (#378) keeps an AiWork stream
    /// stamped with a parent quiet too, while its question still chimes.
    func testAChildIsQuietWhicheverSourceDrivesItsCard() throws {
        let appState = AppState()
        // Hydrate falls back to daemon discovery: keep it off any real daemon.
        appState.aiworkStateDirOverride = "/nonexistent/codeisland-tests/agentix"
        let sessionId = AppState.aiworkSessionPrefix + "acp:coder:kid"
        var child = SessionSnapshot()
        child.source = "aiwork"
        child.providerSessionId = "acp:coder:kid"
        child.parentSessionId = "parent"
        appState.sessions[sessionId] = child

        func stream(_ name: String) throws {
            let frame = try XCTUnwrap(AiWorkWatchClient.parseFrame(Data("""
            {"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"\(name)"},"data":{"session":{"session_id":"acp:coder:kid","cwd":"/tmp/proj"}},"meta":{"session_id":"acp:coder:kid"}}
            """.utf8)))
            appState.handleAiWorkStreamEvent(name: name, frame: frame, agentId: "coder")
        }

        try stream("stream.started")
        try stream("stream.completed")
        XCTAssertEqual(appState.sessions[sessionId]?.parentSessionId, "parent")
        XCTAssertEqual(appState.sessions[sessionId]?.status, .idle)
        XCTAssertEqual(played, [], "a child's turn neither starts nor ends audibly")
        XCTAssertNil(appState.justCompletedSessionId, "and pops no completion card")

        try stream("stream.started")
        try stream("stream.question_required")
        XCTAssertEqual(played, ["8bit_approval"], "the user still has to answer a child's question")
    }

    /// The same card without the stamp is an ordinary session.
    func testTheSameCardWithoutAParentRingsAndCompletes() throws {
        let appState = AppState()
        appState.aiworkStateDirOverride = "/nonexistent/codeisland-tests/agentix"
        let sessionId = AppState.aiworkSessionPrefix + "acp:coder:own"
        var own = SessionSnapshot()
        own.source = "aiwork"
        own.providerSessionId = "acp:coder:own"
        appState.sessions[sessionId] = own

        func stream(_ name: String) throws {
            let frame = try XCTUnwrap(AiWorkWatchClient.parseFrame(Data("""
            {"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"\(name)"},"data":{"session":{"session_id":"acp:coder:own","cwd":"/tmp/proj"}},"meta":{"session_id":"acp:coder:own"}}
            """.utf8)))
            appState.handleAiWorkStreamEvent(name: name, frame: frame, agentId: "coder")
        }

        try stream("stream.started")
        try stream("stream.completed")
        XCTAssertEqual(played, ["8bit_submit", "8bit_complete"])
        XCTAssertEqual(appState.justCompletedSessionId, sessionId)
    }
}
