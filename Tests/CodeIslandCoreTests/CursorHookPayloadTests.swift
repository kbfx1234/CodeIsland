import XCTest
@testable import CodeIslandCore

/// Cursor runs the Claude Code hooks it imports with its own payload (#377).
final class CursorHookPayloadTests: XCTestCase {
    private let conversationId = "5bb4f256-7c1d-4f0e-9a43-1d2b3c4d5e6f"

    /// What Cursor 3.25 handed CodeIsland's Claude Code hook (the reporter's log).
    private var cursorPreToolUse: [String: Any] {
        [
            "conversation_id": conversationId,
            "generation_id": "8f833ac7-1111-4222-8333-944455556666",
            "session_id": conversationId,
            "model": "composer-2.5",
            "hook_event_name": "preToolUse",
            "cursor_version": "3.25.9",
            "workspace_roots": ["/Users/u/project"],
            "user_email": NSNull(),
            "transcript_path": "/Users/u/.cursor/projects/Users-u-project/agent-transcripts/\(conversationId)/\(conversationId).jsonl",
            "tool_name": "Shell",
            "tool_input": ["command": "swift test", "cwd": "", "timeout": 30000] as [String: Any],
            "tool_use_id": "call_1",
            "cwd": "",
        ]
    }

    func testCursorVersionMarksAHookCursorRan() {
        XCTAssertTrue(CursorHookPayload.isCursorHook(cursorPreToolUse))
        // Claude Code's own PreToolUse never carries it.
        XCTAssertFalse(CursorHookPayload.isCursorHook([
            "session_id": "abc",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "transcript_path": "/Users/u/.claude/projects/-Users-u-project/abc.jsonl",
        ]))
        XCTAssertFalse(CursorHookPayload.isCursorHook(["cursor_version": "  "]))
        XCTAssertFalse(CursorHookPayload.isCursorHook(["cursor_version": 3.25]))
        XCTAssertFalse(CursorHookPayload.isCursorHook(["cursor_version": NSNull()]))
    }

    /// Cursor writes one step's payload to every hook of the step: both of
    /// CodeIsland's hooks read the same bytes, so they share a digest.
    func testOneStepDeliveredTwiceSharesADigest() throws {
        let stdin = try JSONSerialization.data(withJSONObject: cursorPreToolUse, options: [.sortedKeys])
        XCTAssertEqual(
            CursorHookPayload.deliveryDigest(of: stdin),
            CursorHookPayload.deliveryDigest(of: Data(stdin))
        )
        XCTAssertEqual(CursorHookPayload.deliveryDigest(of: stdin).count, 64)

        var nextCall = cursorPreToolUse
        nextCall["tool_use_id"] = "call_2"
        let other = try JSONSerialization.data(withJSONObject: nextCall, options: [.sortedKeys])
        XCTAssertNotEqual(CursorHookPayload.deliveryDigest(of: stdin), CursorHookPayload.deliveryDigest(of: other))
    }

    func testDeliveryFilterLetsOneCopyThroughPerWindow() {
        var filter = CursorHookDeliveryFilter(window: 5)
        let start = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertFalse(filter.isRepeat(digest: "stop-turn-1", now: start))
        XCTAssertTrue(filter.isRepeat(digest: "stop-turn-1", now: start.addingTimeInterval(0.05)))
        // A third config with the same hook (a project .claude/settings.json) is dropped too.
        XCTAssertTrue(filter.isRepeat(digest: "stop-turn-1", now: start.addingTimeInterval(0.2)))
        // Another event is never mistaken for it.
        XCTAssertFalse(filter.isRepeat(digest: "prompt-turn-2", now: start.addingTimeInterval(0.3)))
        // Seconds later the same bytes are a new event, not a copy.
        XCTAssertFalse(filter.isRepeat(digest: "stop-turn-1", now: start.addingTimeInterval(5)))
        XCTAssertTrue(filter.isRepeat(digest: "stop-turn-1", now: start.addingTimeInterval(5.1)))
    }

    /// A card saved as Claude by an older bridge turns Cursor on the next
    /// event the new bridge attributes — the same card, not a second one.
    func testPersistedClaudeCardTurnsCursorOnTheNextAttributedEvent() throws {
        var restored = SessionSnapshot()
        restored.source = "claude"
        restored.status = .idle
        restored.termBundleId = "com.todesktop.230313mzl4w4u92"
        var sessions = [conversationId: restored]

        var payload = cursorPreToolUse
        payload["_source"] = "cursor"
        payload["_ppid"] = 900
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[conversationId]?.source, "cursor")
        XCTAssertEqual(sessions[conversationId]?.status, .running)
        XCTAssertEqual(sessions[conversationId]?.currentTool, "Shell")
    }

    /// A new chat's `sessionStart` arrives before Cursor has a transcript for
    /// it; with one other chat on the same IDE pid, the `_ppid` fallback must
    /// not adopt it as that chat's Task (Cursor sends no sessionStart/End for Tasks).
    func testConversationLifecycleIsNeverPpidFolded() {
        for event in ["sessionStart", "sessionEnd", "SessionStart"] {
            XCTAssertFalse(
                CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                    "_source": "cursor",
                    "session_id": conversationId,
                    "hook_event_name": event,
                    "transcript_path": NSNull(),
                    "_ppid": 900,
                ]),
                event
            )
        }
        // A Task's own hooks (no transcript, same pid) still may.
        XCTAssertTrue(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": conversationId,
                "hook_event_name": "preToolUse",
                "transcript_path": NSNull(),
                "_ppid": 900,
            ])
        )
    }
}
