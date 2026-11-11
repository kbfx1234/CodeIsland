import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Companion devices (iPhone / Watch via AppleCompanionPublisher, the ESP32
/// Buddy) get the same marker-free reply text as the island's previews.
@MainActor
final class CompanionPreviewMarkdownTests: XCTestCase {
    private let reply = "## Summary\n- **fixed** the `auth` bug\n\n| a | b |\n|---|---|\n| 1 | 2 |"
    private let flattened = "Summary · fixed the auth bug · a, b · 1, 2"

    private func appState(with messages: [ChatMessage], status: AgentStatus = .processing) -> AppState {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = status
        session.cwd = "/tmp/web-app"
        session.lastActivity = Date()
        for message in messages { session.addRecentMessage(message) }
        appState.sessions["s1"] = session
        appState.activeSessionId = "s1"
        appState.refreshDerivedState()
        return appState
    }

    func testAppleCompanionPayloadSendsFlattenedReplies() {
        let prompt = "fix `auth` **now**"
        let state = appState(with: [ChatMessage(isUser: true, text: prompt), ChatMessage(isUser: false, text: reply)])
        let payload = state.appleCompanionStatePayload(sequence: 1)

        XCTAssertEqual(payload.messages.map(\.text), [prompt, flattened], "user prompts stay literal")
        XCTAssertEqual(payload.sessions.first?.messages.map(\.text), [prompt, flattened])
        XCTAssertEqual(payload.sessions.first?.message, flattened)
    }

    func testSessionMessageFallsBackToFlattenedLastReply() {
        let state = appState(with: [])
        state.sessions["s1"]?.lastAssistantMessage = reply
        XCTAssertEqual(state.appleCompanionStatePayload(sequence: 1).sessions.first?.message, flattened)
    }

    func testBuddyPreviewSegmentsCarryNoMarkdown() {
        let state = appState(with: [ChatMessage(isUser: false, text: reply)])
        let text = state.esp32MessagePreviewPayloads(session: state.esp32DisplaySession()).compactMap(\.text).joined()
        XCTAssertEqual(text, flattened)
    }

    func testFlatteningKeepsAsterisksUnderscoresAndTildesThatAreText() {
        // These used to reach the phone as "234 = 24", "init.py" and "/code/a".
        XCTAssertEqual(
            AppState.companionReplyText("- **Fixed**: 2*3*4 = 24 in `calc.py`\n- edited __init__.py under ~/code/a, see a~b~c"),
            "Fixed: 2*3*4 = 24 in calc.py · edited __init__.py under ~/code/a, see a~b~c"
        )
    }

    func testFlatteningLeavesUserMessagesAlone() {
        let messages = [ChatMessage(isUser: true, text: "# not a heading, a prompt"), ChatMessage(isUser: false, text: "# Title")]
        XCTAssertEqual(AppState.companionMessages(messages).map(\.text), ["# not a heading, a prompt", "Title"])
    }
}
