import XCTest
@testable import CodeIsland

@MainActor
final class HookServerCodexCanonicalizationTests: XCTestCase {
    private func makeTranscript(firstLine: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-hook-codex-\(UUID().uuidString).jsonl")
        try (firstLine + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func canonicalizedPayload(_ payload: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let rewritten = HookServer.canonicalizeCodexDesktopHookPayload(data: data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    }

    func testDesktopTranscriptWithoutTerminalMarkerGetsCodexAppBundle() throws {
        let transcript = try makeTranscript(firstLine: #"{"type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode"}}"#)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let payload = try canonicalizedPayload([
            "hook_event_name": "SessionStart",
            "session_id": "desktop-thread",
            "_source": "codex",
            "transcript_path": transcript.path,
        ])

        XCTAssertEqual(payload["_term_bundle"] as? String, AppState.codexAppBundleId)
    }

    func testDesktopTranscriptWithCmuxSurfaceDoesNotGetCodexAppBundle() throws {
        let transcript = try makeTranscript(firstLine: #"{"type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode"}}"#)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let payload = try canonicalizedPayload([
            "hook_event_name": "SessionStart",
            "session_id": "desktop-thread",
            "_source": "codex",
            "transcript_path": transcript.path,
            "_cmux_surface_id": "surface-1",
        ])

        XCTAssertNil(payload["_term_bundle"])
    }

    func testCLITranscriptWithoutTerminalMarkerStaysUnchanged() throws {
        let transcript = try makeTranscript(firstLine: #"{"type":"session_meta","payload":{"originator":"Codex CLI","source":"cli"}}"#)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let payload = try canonicalizedPayload([
            "hook_event_name": "SessionStart",
            "session_id": "cli-thread",
            "_source": "codex",
            "transcript_path": transcript.path,
        ])

        XCTAssertNil(payload["_term_bundle"])
    }

    func testExistingTerminalBundleIsNeverOverwritten() throws {
        let transcript = try makeTranscript(firstLine: #"{"type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode"}}"#)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let payload = try canonicalizedPayload([
            "hook_event_name": "SessionStart",
            "session_id": "desktop-thread",
            "_source": "codex",
            "_term_bundle": "com.apple.Terminal",
            "transcript_path": transcript.path,
        ])

        XCTAssertEqual(payload["_term_bundle"] as? String, "com.apple.Terminal")
    }

    func testDesktopSubagentHookUsesChildTranscriptId() throws {
        let transcript = try makeTranscript(firstLine: #"{"type":"session_meta","payload":{"session_id":"parent-thread","id":"child-thread","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread"}}}}}"#)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let payload = try canonicalizedPayload([
            "hook_event_name": "SessionStart",
            "session_id": "parent-thread",
            "_source": "codex",
            "transcript_path": transcript.path,
        ])

        XCTAssertEqual(payload["session_id"] as? String, "child-thread")
        XCTAssertEqual(payload["_term_bundle"] as? String, AppState.codexAppBundleId)
    }
}
