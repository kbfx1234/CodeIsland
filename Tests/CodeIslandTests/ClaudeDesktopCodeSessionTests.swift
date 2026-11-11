import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A Claude Code session run from Claude Desktop's Code tab jumps to that exact
/// session through `claude://code/continue?session=<local_…>`. The hook's
/// session_id is the CLI's id, which that link refuses; Claude Desktop's own id
/// arrives from CLAUDE_CODE_HOST_SESSION_ID via the bridge.
final class ClaudeDesktopCodeSessionTests: XCTestCase {
    private let hostId = "local_835c10bc-3a81-46b9-80c3-b5356e034bd6"

    func testAcceptsOnlyTheShapeClaudeDesktopsLinkAccepts() {
        XCTAssertTrue(ClaudeDesktopCodeSession.isValidHostSessionId(hostId))
        XCTAssertTrue(ClaudeDesktopCodeSession.isValidHostSessionId("local_a"))
        XCTAssertTrue(ClaudeDesktopCodeSession.isValidHostSessionId("local_" + String(repeating: "a", count: 64)))

        for bad in [
            "c171108a-2861-4f57-bc58-d75009ec9c19",    // the CLI's id: refused by the link
            "last",                                    // the link's own keyword, not a session
            "local_",
            "local_" + String(repeating: "a", count: 65),
            "local_abc&session=other",                  // must not smuggle query parameters
            "local_../../settings",
            "local_ab cd",
            "local_ábc",
            "LOCAL_abc",
        ] {
            XCTAssertFalse(ClaudeDesktopCodeSession.isValidHostSessionId(bad), bad)
            XCTAssertNil(ClaudeDesktopCodeSession.deepLinkURL(hostSessionId: bad), bad)
        }
    }

    func testDeepLinkOpensThatSession() {
        XCTAssertEqual(
            ClaudeDesktopCodeSession.deepLinkURL(hostSessionId: hostId)?.absoluteString,
            "claude://code/continue?session=\(hostId)"
        )
    }

    func testHostIdIsCapturedFromTheHookPayload() throws {
        var sessions: [String: SessionSnapshot] = ["s": SessionSnapshot()]
        extractMetadata(into: &sessions, sessionId: "s", event: try makeEvent(["_claude_desktop_session": hostId]))
        XCTAssertEqual(sessions["s"]?.claudeDesktopSessionId, hostId)
    }

    func testMalformedHostIdIsDropped() throws {
        var sessions: [String: SessionSnapshot] = ["s": SessionSnapshot()]
        extractMetadata(into: &sessions, sessionId: "s", event: try makeEvent(["_claude_desktop_session": "local_x&y=1"]))
        XCTAssertNil(sessions["s"]?.claudeDesktopSessionId, "it ends up in a URL on click")
    }

    func testHostIdIsCapturedFromAPluginsEnvBlock() throws {
        var sessions: [String: SessionSnapshot] = ["s": SessionSnapshot()]
        extractMetadata(
            into: &sessions, sessionId: "s",
            event: try makeEvent(["_env": [ClaudeDesktopCodeSession.hostSessionEnvKey: hostId]])
        )
        XCTAssertEqual(sessions["s"]?.claudeDesktopSessionId, hostId)
    }

    func testHostIdSurvivesSessionStart() throws {
        // SessionStart rebuilds the card after the common extraction ran, and
        // it is the first hook every Code-tab session sends (and again after
        // /clear or a compaction).
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: try makeEvent(["_claude_desktop_session": hostId]), maxHistory: 10)
        XCTAssertEqual(sessions["s"]?.claudeDesktopSessionId, hostId)
    }

    func testASubagentHookFillsAParentThatHasNoHostIdYet() throws {
        // Subagents run inside the same CLI, so they carry the same host id.
        var sessions: [String: SessionSnapshot] = ["s": SessionSnapshot()]
        let event = try makeEvent([
            "hook_event_name": "PreToolUse", "agent_id": "a1", "_claude_desktop_session": hostId,
        ])
        XCTAssertNotNil(event.agentId)
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)
        XCTAssertEqual(sessions["s"]?.claudeDesktopSessionId, hostId)
    }

    func testSessionsFileWithoutTheFieldStillDecodes() throws {
        // sessions.json written before the field existed.
        let json = #"[{"sessionId":"s","source":"claude","startTime":"2026-09-28T00:00:00Z","lastActivity":"2026-09-28T00:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode([PersistedSession].self, from: Data(json.utf8))
        XCTAssertNil(restored.first?.claudeDesktopSessionId)
    }

    private func makeEvent(_ extra: [String: Any]) throws -> HookEvent {
        var payload: [String: Any] = ["hook_event_name": "SessionStart", "session_id": "s"]
        for (key, value) in extra { payload[key] = value }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
