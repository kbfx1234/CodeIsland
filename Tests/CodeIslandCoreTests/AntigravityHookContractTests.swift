import XCTest
@testable import CodeIslandCore

/// #339 — Antigravity's PreToolUse gate fails closed and ignores `allow`, so the
/// island answers every Antigravity PreToolUse with `ask` and never holds it.
final class AntigravityHookContractTests: XCTestCase {
    func testAntigravityPreToolUseDefersToNativePermissionWithADocumentedDecision() throws {
        let stdout = try XCTUnwrap(
            AntigravityHookContract.hookStdout(source: "google-antigravity", eventName: "PreToolUse")
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        )
        // Exactly one field, camelCase, from the documented vocabulary
        // (allow | deny | ask | force_ask | deny_unless_prior_grant).
        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(object["decision"] as? String, "ask")
    }

    func testAliasesOfAgyGetTheSameAnswer() {
        for source in ["agy", "antigravity-cli", "Google-Antigravity"] {
            XCTAssertEqual(
                AntigravityHookContract.hookStdout(source: source, eventName: "PreToolUse"),
                #"{"decision":"ask"}"#,
                source
            )
        }
    }

    /// Gemini CLI has no PreToolUse — only agy reading `--source gemini` hooks
    /// sends one — so it gets the Antigravity answer. Gemini CLI's own
    /// BeforeTool approval keeps its blocking island card.
    func testGeminiTaggedPreToolUseIsAgyButBeforeToolIsNot() {
        XCTAssertTrue(AntigravityHookContract.isAntigravityPreToolUse(source: "gemini", eventName: "PreToolUse"))
        XCTAssertFalse(AntigravityHookContract.isAntigravityPreToolUse(source: "gemini", eventName: "BeforeTool"))
    }

    func testOtherEventsAndAgentsOweNoDecision() {
        for event in ["PostToolUse", "Stop", "PreInvocation", "PostInvocation"] {
            XCTAssertNil(AntigravityHookContract.hookStdout(source: "google-antigravity", eventName: event), event)
        }
        // The Claude-Code fork that happens to be called "antigravity" is not Google's.
        XCTAssertNil(AntigravityHookContract.hookStdout(source: "antigravity", eventName: "PreToolUse"))
        XCTAssertNil(AntigravityHookContract.hookStdout(source: "claude", eventName: "PreToolUse"))
        XCTAssertNil(AntigravityHookContract.hookStdout(source: nil, eventName: "PreToolUse"))
        XCTAssertNil(AntigravityHookContract.hookStdout(source: "google-antigravity", eventName: nil))
    }
}
