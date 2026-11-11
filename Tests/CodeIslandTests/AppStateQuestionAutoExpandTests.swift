import XCTest
@testable import CodeIsland
import CodeIslandCore

/// "Auto-expand on question": questions used to open their card no matter
/// what, even for users who had turned off auto-expand for approvals (#292).
@MainActor
final class AppStateQuestionAutoExpandTests: XCTestCase {
    private var savedAutoExpandOnQuestion: Any?
    private var savedSmartSuppress: Any?

    override func setUp() {
        super.setUp()
        savedAutoExpandOnQuestion = UserDefaults.standard.object(forKey: SettingsKey.autoExpandOnQuestion)
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
        // Keep Smart Suppress out of the way: these tests are about the new switch.
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        restore(savedAutoExpandOnQuestion, forKey: SettingsKey.autoExpandOnQuestion)
        restore(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        super.tearDown()
    }

    func testDefaultIsOnSoNothingChangesUnlessAsked() {
        let suite = "AppStateQuestionAutoExpandTests.default"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(AppState.autoExpandOnQuestion(defaults))
        defaults.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        XCTAssertFalse(AppState.autoExpandOnQuestion(defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    func testAskUserQuestionStillOpensItsCardWhenOn() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let task = try await startAskUserQuestion(on: appState, sessionId: "s-on")

        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-on"))
        XCTAssertNil(appState.hiddenPendingQuestionSessionId, "nothing hidden while the card is up")
        appState.skipQuestion(expectedSessionId: "s-on")
        _ = try await awaitValue(of: task)
    }

    func testOffKeepsTheIslandCollapsedAndAdvertisesTheQuestion() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let task = try await startAskUserQuestion(on: appState, sessionId: "s-off")

        XCTAssertEqual(appState.surface, .collapsed, "the card must not open by itself")
        XCTAssertEqual(appState.questionQueue.count, 1, "the question still waits for an answer")
        XCTAssertEqual(appState.sessions["s-off"]?.status, .waitingQuestion)
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "s-off", "the collapsed bar shows the badge")

        // One click opens it.
        appState.openPendingQuestionCard()
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-off"))
        XCTAssertNil(appState.hiddenPendingQuestionSessionId)

        appState.skipQuestion(expectedSessionId: "s-off")
        _ = try await awaitValue(of: task)
    }

    func testOffAlsoCoversNotificationStyleQuestions() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "session_id": "s-notify",
            "question": "Continue?",
            "options": ["Yes", "No"],
        ] as [String: Any])))
        let task = await startHookRequest { appState.handleQuestion(event, continuation: $0) }

        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "s-notify")
        appState.skipQuestion(expectedSessionId: "s-notify")
        _ = try await awaitValue(of: task)
    }

    /// A card the user opened with a click must survive the queue being
    /// re-evaluated (another request resolving, a completion timer firing):
    /// "off" means nothing opens by itself, not that the user's card closes.
    func testCardOpenedByClickSurvivesShowNextPending() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let task = try await startAskUserQuestion(on: appState, sessionId: "s-click")

        appState.openPendingQuestionCard(sessionId: "s-click")
        XCTAssertTrue(appState.showNextPending())
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-click"))

        appState.skipQuestion(expectedSessionId: "s-click")
        _ = try await awaitValue(of: task)
    }

    func testOpeningWithoutAPendingQuestionIsANoOp() {
        let appState = AppState()
        appState.openPendingQuestionCard()
        XCTAssertEqual(appState.surface, .collapsed)
        appState.openPendingQuestionCard(sessionId: "no-such-session")
        XCTAssertEqual(appState.surface, .collapsed)
    }

    // MARK: - Helpers

    private func startAskUserQuestion(on appState: AppState, sessionId: String) async throws -> Task<Data, Never> {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": "Which approach?",
                    "header": "Approach",
                    "options": [
                        ["label": "A", "description": ""],
                        ["label": "B", "description": ""],
                    ],
                ] as [String: Any]],
            ],
        ]
        let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
        return await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
