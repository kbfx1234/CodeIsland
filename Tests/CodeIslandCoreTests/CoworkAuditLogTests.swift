import XCTest
@testable import CodeIslandCore

/// `audit.jsonl` parsing and the turn-state reducer. Lines reproduce the real
/// record shapes: SDK messages as the in-VM CLI emits them, plus Claude
/// Desktop's own `permission_request` / `permission_response` records.
final class CoworkAuditLogTests: XCTestCase {

    // MARK: - Fixtures

    private static let ts = #""_audit_timestamp":"2026-01-13T10:39:52.333Z""#

    static let userPrompt = #"{"type":"user","uuid":"u1","session_id":"f421","parent_tool_use_id":null,"message":{"role":"user","content":"list the installers"},"# + ts + "}"
    static let systemInit = #"{"type":"system","subtype":"init","cwd":"/sessions/bold-inspiring-tesla","session_id":"d0a5","tools":["Bash","Read"],"model":"claude-opus-4-5-20251101","permissionMode":"default","uuid":"s1","# + ts + "}"
    static let assistantText = #"{"type":"assistant","message":{"model":"claude-opus-4-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Let me look."}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"a1","# + ts + "}"
    static let assistantToolUse = #"{"type":"assistant","message":{"model":"claude-opus-4-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"find /sessions/bold-inspiring-tesla/mnt/alice -name \"*.dmg\""}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"a2","# + ts + "}"
    static let toolResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"a.dmg","is_error":false}]},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"u2","tool_use_result":{"stdout":"a.dmg"},"# + ts + "}"
    static let assistantReply = #"{"type":"assistant","message":{"model":"claude-opus-4-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Found a.dmg"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"d0a5","uuid":"a3","# + ts + "}"
    static let resultSuccess = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":50948,"num_turns":2,"result":"Found a.dmg","session_id":"d0a5","total_cost_usd":0.24,"permission_denials":[],"uuid":"r1","# + ts + "}"
    /// Claude Desktop's Stop button: the CLI ends the turn with an error
    /// result that says why (`terminal_reason`), and no `result` text.
    static let resultStoppedMidReply = #"{"type":"result","subtype":"error_during_execution","duration_ms":8123,"duration_api_ms":4012,"is_error":true,"num_turns":1,"stop_reason":null,"session_id":"d0a5","total_cost_usd":0.05,"permission_denials":[],"terminal_reason":"aborted_streaming","errors":["stopped"],"uuid":"r2","# + ts + "}"
    /// Stopped while a tool ran, after a clean text step: a success-shaped
    /// result that still carries the abort.
    static let resultStoppedDuringTool = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":9001,"num_turns":2,"result":"Looking at the installers","stop_reason":null,"session_id":"d0a5","permission_denials":[],"terminal_reason":"aborted_tools","uuid":"r3","# + ts + "}"

    static func permissionRequest(id: String, tool: String, input: String) -> String {
        #"{"type":"system","subtype":"permission_request","uuid":""# + id + #"","session_id":"d0a5","tool_name":""# + tool + #"","tool_input":"# + input + "," + ts + "}"
    }

    static func permissionResponse(id: String) -> String {
        #"{"type":"system","subtype":"permission_response","uuid":""# + id + #"","session_id":"d0a5","tool_name":"Bash","decision":"allow_once","granted":true,"# + ts + "}"
    }

    private func event(_ line: String) -> CoworkAuditEvent {
        CoworkAuditParser.event(fromLine: Data(line.utf8))
    }

    private func state(after lines: [String]) -> CoworkAuditState {
        var state = CoworkAuditState()
        state.apply(lines.map(event))
        return state
    }

    // MARK: - Parser

    func testParsesARealTurn() {
        XCTAssertEqual(event(Self.userPrompt), .userPrompt(text: "list the installers", isSynthetic: false))
        XCTAssertEqual(event(Self.systemInit), .turnActivity)
        XCTAssertEqual(event(Self.assistantText), .assistantOutput(isSubagent: false, toolUse: nil))
        XCTAssertEqual(
            event(Self.assistantToolUse),
            .assistantOutput(isSubagent: false, toolUse: .init(name: "Bash", detail: #"find alice -name "*.dmg""#))
        )
        XCTAssertEqual(event(Self.toolResult), .toolResult)
        XCTAssertEqual(event(Self.resultSuccess), .turnEnded(isError: false, resultText: "Found a.dmg"))
    }

    func testPromptWithContentBlocksAndSyntheticNotification() {
        let blocks = #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"describe this"}]},"parent_tool_use_id":null}"#
        XCTAssertEqual(event(blocks), .userPrompt(text: "describe this", isSynthetic: false))
        let synthetic = #"{"type":"user","uuid":"x","session_id":"d0a5","parent_tool_use_id":null,"client_platform":"desktop_app","isSynthetic":true,"message":{"role":"user","content":[{"type":"text","text":"Task finished"}]}}"#
        XCTAssertEqual(event(synthetic), .userPrompt(text: "Task finished", isSynthetic: true))
    }

    func testFailedResultIsAnErrorEvenWhenOnlyTheSubtypeSaysSo() {
        let flagged = #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"d0a5"}"#
        XCTAssertEqual(event(flagged), .turnEnded(isError: true, resultText: nil))
        let subtypeOnly = #"{"type":"result","subtype":"error_max_turns","session_id":"d0a5"}"#
        XCTAssertEqual(event(subtypeOnly), .turnEnded(isError: true, resultText: nil))
        // Any other terminal reason is still what the subtype says.
        let apiError = #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"api_error"}"#
        XCTAssertEqual(event(apiError), .turnEnded(isError: true, resultText: nil))
    }

    func testStoppedTurnIsAnInterruptionNotAFailure() {
        XCTAssertEqual(
            event(Self.resultStoppedMidReply),
            .turnEnded(isError: false, resultText: nil, interrupted: true)
        )
        XCTAssertEqual(
            event(Self.resultStoppedDuringTool),
            .turnEnded(isError: false, resultText: "Looking at the installers", interrupted: true)
        )
        XCTAssertEqual(event(Self.resultSuccess), .turnEnded(isError: false, resultText: "Found a.dmg", interrupted: false))
    }

    func testStoppedTurnIsRecognisedWithoutParsingAnOversizedResult() {
        let payload = String(repeating: "x", count: CoworkAuditParser.maxParsedLineBytes)
        let stopped = #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_tools","errors":[""# + payload + #""]}"#
        XCTAssertEqual(event(stopped), .turnEnded(isError: false, resultText: nil, interrupted: true))
        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":[""# + payload + #""]}"#
        XCTAssertEqual(event(failed), .turnEnded(isError: true, resultText: nil, interrupted: false))
    }

    func testPermissionRecords() {
        let request = Self.permissionRequest(
            id: "req-1", tool: "Bash",
            input: #"{"command":"rm -rf /sessions/bold-inspiring-tesla/mnt/alice/tmp"}"#
        )
        XCTAssertEqual(event(request), .permissionRequested(id: "req-1", toolName: "Bash", detail: "rm -rf alice/tmp"))
        XCTAssertEqual(event(Self.permissionResponse(id: "req-1")), .permissionResolved(id: "req-1"))

        let question = Self.permissionRequest(
            id: "req-2", tool: "AskUserQuestion",
            input: #"{"questions":[{"question":"Which folder?","header":"Folder","options":[{"label":"A"}]},{"question":"Overwrite?"}]}"#
        )
        XCTAssertEqual(
            event(question),
            .permissionRequested(id: "req-2", toolName: "AskUserQuestion", detail: "Which folder? (+1)")
        )

        let auto = #"{"type":"system","subtype":"permission_auto_approved","session_id":"d0a5","tool_name":"Read","source":"session_rule_cache"}"#
        XCTAssertEqual(event(auto), .ignored)
    }

    func testSubagentOutputIsFlagged() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"sub"}]},"parent_tool_use_id":"toolu_task","session_id":"d0a5"}"#
        XCTAssertEqual(event(line), .assistantOutput(isSubagent: true, toolUse: nil))
    }

    func testQuotedMarkersInsideContentDoNotFoolTheByteProbes() {
        // A prompt that *talks about* tool results is still a prompt: quotes in
        // string values are escaped, so the markers cannot match.
        let line = #"{"type":"user","message":{"role":"user","content":"what does \"type\":\"tool_result\" mean?"},"parent_tool_use_id":null}"#
        XCTAssertEqual(event(line), .userPrompt(text: #"what does "type":"tool_result" mean?"#, isSynthetic: false))
    }

    func testOversizedLinesNeverReachTheJSONParser() {
        // A multi-megabyte Write tool call: recognised as a (main-agent) tool
        // step from byte markers alone; the unparsed input just loses its detail.
        let payload = String(repeating: "x", count: CoworkAuditParser.maxParsedLineBytes)
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Write","input":{"content":""# + payload + #""}}]},"parent_tool_use_id":null}"#
        XCTAssertEqual(event(line), .assistantOutput(isSubagent: false, toolUse: nil))

        // `init` is recognised by its prefix even when the rest is not JSON we can read.
        XCTAssertEqual(event(#"{"type":"system","subtype":"init","tools":[truncated"#), .turnActivity)
    }

    func testMalformedAndUnknownLinesAreIgnored() {
        XCTAssertEqual(event("not json"), .ignored)
        XCTAssertEqual(event(#"{"type":"stream_event","event":{}}"#), .ignored)
        XCTAssertEqual(event(#"{"type":"system","subtype":"compact_boundary"}"#), .ignored)
        // Key order is not guaranteed by every writer: fall back to a parse.
        XCTAssertEqual(event(#"{"uuid":"r","type":"result","subtype":"success","is_error":false}"#),
                       .turnEnded(isError: false, resultText: nil))
    }

    func testSplitKeepsTheLineStillBeingWritten() {
        let blob = Data((Self.userPrompt + "\n" + Self.systemInit + "\n" + #"{"type":"assi"#).utf8)
        let parsed = CoworkAuditParser.events(in: blob)
        XCTAssertEqual(parsed.events, [.userPrompt(text: "list the installers", isSynthetic: false), .turnActivity])
        XCTAssertEqual(String(data: parsed.trailingFragment, encoding: .utf8), #"{"type":"assi"#)
    }

    // MARK: - Reducer

    func testRealTurnWalksProcessingRunningIdle() {
        var state = CoworkAuditState()
        XCTAssertEqual(state.phase, .idle)

        state.apply(event(Self.userPrompt))
        XCTAssertEqual(state.phase, .processing)
        XCTAssertEqual(state.promptCount, 1)
        XCTAssertEqual(state.lastPrompt, "list the installers")

        state.apply([event(Self.systemInit), event(Self.assistantText), event(Self.assistantToolUse)])
        XCTAssertEqual(state.phase, .processing)
        XCTAssertEqual(state.currentTool?.name, "Bash")

        state.apply(event(Self.toolResult))
        XCTAssertEqual(state.currentTool?.name, "Bash", "a finished tool lingers until the model speaks again")

        state.apply(event(Self.assistantReply))
        XCTAssertNil(state.currentTool)

        state.apply(event(Self.resultSuccess))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.completedTurnCount, 1)
        XCTAssertEqual(state.lastResultText, "Found a.dmg")
        XCTAssertFalse(state.lastTurnFailed)
    }

    func testPermissionCardWaitsUntilAnswered() {
        let request = Self.permissionRequest(id: "req-1", tool: "Bash", input: #"{"command":"rm x"}"#)
        var state = self.state(after: [Self.userPrompt, Self.assistantToolUse, request])
        XCTAssertEqual(state.phase, .waitingApproval)
        XCTAssertEqual(state.activePermission?.toolName, "Bash")
        XCTAssertEqual(state.activePermission?.detail, "rm x")
        XCTAssertEqual(state.permissionRequestCount, 1)

        state.apply(event(Self.permissionResponse(id: "req-1")))
        XCTAssertEqual(state.phase, .processing)
        XCTAssertTrue(state.pendingPermissions.isEmpty)
    }

    func testAskUserQuestionIsAQuestionWait() {
        let question = Self.permissionRequest(
            id: "q", tool: "AskUserQuestion", input: #"{"questions":[{"question":"Which folder?"}]}"#
        )
        let state = self.state(after: [Self.userPrompt, question])
        XCTAssertEqual(state.phase, .waitingQuestion)
        XCTAssertEqual(state.activePermission?.detail, "Which folder?")
    }

    func testParallelCardsResolveById() {
        let first = Self.permissionRequest(id: "a", tool: "Bash", input: #"{"command":"one"}"#)
        let second = Self.permissionRequest(id: "b", tool: "WebFetch", input: #"{"url":"https://x"}"#)
        var state = self.state(after: [Self.userPrompt, first, second])
        XCTAssertEqual(state.activePermission?.toolName, "WebFetch")

        state.apply(event(Self.permissionResponse(id: "b")))
        XCTAssertEqual(state.phase, .waitingApproval, "the other card is still up")
        XCTAssertEqual(state.activePermission?.id, "a")

        state.apply(event(Self.permissionResponse(id: "a")))
        XCTAssertEqual(state.phase, .processing)
    }

    func testMainAgentOutputClearsCardsClaudeDesktopNeverAnswered() {
        // Superseded/aborted requests are resolved without a response record;
        // the main agent speaking again proves nothing is still blocked.
        let stale = Self.permissionRequest(id: "stale", tool: "Bash", input: #"{"command":"x"}"#)
        let state = self.state(after: [Self.userPrompt, stale, Self.assistantReply])
        XCTAssertEqual(state.phase, .processing)
        XCTAssertTrue(state.pendingPermissions.isEmpty)
    }

    func testSubagentOutputDoesNotClearAMainAgentCard() {
        let request = Self.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"x"}"#)
        let subagent = #"{"type":"assistant","message":{"content":[{"type":"text","text":"sub"}]},"parent_tool_use_id":"toolu_task"}"#
        let state = self.state(after: [Self.userPrompt, request, subagent, Self.toolResult])
        XCTAssertEqual(state.phase, .waitingApproval)
    }

    func testTurnEndClearsCardsAndRecordsFailure() {
        let request = Self.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"x"}"#)
        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true}"#
        let state = self.state(after: [Self.userPrompt, request, failed])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.pendingPermissions.isEmpty)
        XCTAssertTrue(state.lastTurnFailed)
        XCTAssertEqual(state.completedTurnCount, 1)
    }

    func testTurnResumedWithoutAUserLineStillCompletes() {
        // Claude Desktop resumes some turns itself (workflow notifications):
        // the CLI restarts and answers with no user record in between.
        let state = self.state(after: [Self.systemInit, Self.assistantReply, Self.resultSuccess])
        XCTAssertEqual(state.promptCount, 0)
        XCTAssertEqual(state.completedTurnCount, 1)
        XCTAssertEqual(state.phase, .idle)
    }

    func testNewPromptResetsTheLastTurnsOutcome() {
        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}"#
        var state = self.state(after: [Self.userPrompt, failed])
        XCTAssertTrue(state.lastTurnFailed)
        state.apply(event(Self.userPrompt))
        XCTAssertFalse(state.lastTurnFailed)
        XCTAssertNil(state.lastResultText)
    }

    func testStoppedTurnEndsIdleAsInterrupted() {
        let request = Self.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"x"}"#)
        var state = self.state(after: [Self.userPrompt, Self.assistantToolUse, request, Self.resultStoppedMidReply])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.pendingPermissions.isEmpty, "the card went away with the turn")
        XCTAssertNil(state.currentTool)
        XCTAssertTrue(state.lastTurnInterrupted)
        XCTAssertFalse(state.lastTurnFailed)
        XCTAssertEqual(state.completedTurnCount, 1, "still a turn boundary")

        state.apply(event(Self.userPrompt))
        XCTAssertFalse(state.lastTurnInterrupted)
        state.apply(event(Self.resultSuccess))
        XCTAssertFalse(state.lastTurnInterrupted)
    }
}
