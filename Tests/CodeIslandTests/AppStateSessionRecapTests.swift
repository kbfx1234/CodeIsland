import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Session recap wiring in AppState: live tail deltas, the attach-time
/// backfill that drops superseded recaps, and persistence.
@MainActor
final class AppStateSessionRecapTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-AppStateSessionRecapTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func recapLine(_ text: String, timestamp: String = "2026-09-12T03:35:41.545Z") -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"away_summary","content":"\#(text) (disable recaps in /config)","timestamp":"\#(timestamp)","uuid":"u","isMeta":false,"sessionId":"s"}"#
    }

    private func userLine(_ text: String) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u"}"#
    }

    private func assistantLine(model: String, effort: String, sidechain: Bool = false) -> String {
        #"{"parentUuid":"p","isSidechain":\#(sidechain),"message":{"model":"\#(model)","role":"assistant","content":[{"type":"text","text":"ok"}]},"type":"assistant","effort":"\#(effort)","uuid":"u"}"#
    }

    private func writeTranscript(_ lines: [String], name: String = "session.jsonl") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - Live tail

    func testRecapDeltaLandsOnTheSessionWithoutBumpingActivity() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.status = .idle
        let lastActivity = Date(timeIntervalSince1970: 5_000)
        session.lastActivity = lastActivity
        appState.sessions["s1"] = session

        let recap = SessionRecap(text: "Deployed; waiting on your call.", createdAt: Date())
        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            sessionRecap: recap
        ))

        XCTAssertEqual(appState.sessions["s1"]?.recap, recap)
        XCTAssertEqual(appState.sessions["s1"]?.lastActivity, lastActivity)
    }

    func testPromptDeltaClearsTheRecap() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.recap = SessionRecap(text: "old", createdAt: Date().addingTimeInterval(-60))
        appState.sessions["s1"] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: "new task",
            lastAssistantMessage: nil
        ))

        XCTAssertNil(appState.sessions["s1"]?.recap)
        XCTAssertEqual(appState.sessions["s1"]?.lastUserPrompt, "new task")
    }

    // MARK: - Attach-time backfill

    func testAttachBackfillsRecapModelAndEffort() throws {
        let path = try writeTranscript([
            userLine("ship it"),
            assistantLine(model: "claude-opus-5-5", effort: "xhigh"),
            recapLine("Shipped v2."),
        ])
        let appState = AppState()
        var session = SessionSnapshot()
        session.transcriptPath = path
        appState.sessions["s1"] = session

        appState.attachTranscriptTailerIfNeeded(sessionId: "s1")
        defer { appState.detachTranscriptTailer(sessionId: "s1") }

        XCTAssertEqual(appState.sessions["s1"]?.recap?.text, "Shipped v2.")
        XCTAssertEqual(appState.sessions["s1"]?.model, "claude-opus-5-5")
        XCTAssertEqual(appState.sessions["s1"]?.reasoningEffort, "xhigh")
    }

    func testAttachDropsARestoredRecapThatANewerPromptSuperseded() throws {
        let path = try writeTranscript([
            recapLine("Old recap"),
            userLine("typed while the island was closed"),
            assistantLine(model: "claude-opus-5-5", effort: "high"),
        ])
        let appState = AppState()
        var session = SessionSnapshot()
        session.transcriptPath = path
        session.recap = SessionRecap(text: "Old recap", createdAt: Date(timeIntervalSince1970: 1))
        appState.sessions["s1"] = session

        appState.attachTranscriptTailerIfNeeded(sessionId: "s1")
        defer { appState.detachTranscriptTailer(sessionId: "s1") }

        XCTAssertNil(appState.sessions["s1"]?.recap)
    }

    func testAttachAfterALocalSlashCommandKeepsTheRecapAndTheRealPrompt() throws {
        let path = try writeTranscript([
            userLine("ship it"),
            assistantLine(model: "claude-opus-5-5", effort: "xhigh"),
            recapLine("Shipped v2."),
            #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"isMeta":true,"uuid":"c"}"#,
            #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/effort</command-name>\n            <command-message>effort</command-message>\n            <command-args>high</command-args>"},"uuid":"e"}"#,
            #"{"parentUuid":"e","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>Set effort level to high</local-command-stdout>"},"uuid":"o"}"#,
        ])
        let appState = AppState()
        var session = SessionSnapshot()
        session.transcriptPath = path
        appState.sessions["s1"] = session

        appState.attachTranscriptTailerIfNeeded(sessionId: "s1")
        defer { appState.detachTranscriptTailer(sessionId: "s1") }

        XCTAssertEqual(appState.sessions["s1"]?.recap?.text, "Shipped v2.")
        XCTAssertEqual(appState.sessions["s1"]?.lastUserPrompt, "ship it")
    }

    func testAPromptBeingWrittenAtAttachStillClearsTheRestoredRecap() async throws {
        // The prompt row is half-written when the attach scan runs: the scan
        // can't parse it, so the recap survives it. The tailer must pick the
        // row up from where the scan stopped rather than from the file's end.
        let prompt = userLine("typed right as the island attached") + "\n"
        let cut = prompt.index(prompt.startIndex, offsetBy: prompt.count / 2)
        let url = tempDir.appendingPathComponent("attach-gap.jsonl")
        try (recapLine("Old recap") + "\n" + String(prompt[..<cut])).write(to: url, atomically: true, encoding: .utf8)

        let appState = AppState()
        var session = SessionSnapshot()
        session.transcriptPath = url.path
        session.recap = SessionRecap(text: "Old recap", createdAt: Date(timeIntervalSince1970: 1))
        appState.sessions["s1"] = session
        appState.attachTranscriptTailerIfNeeded(sessionId: "s1")
        defer { appState.detachTranscriptTailer(sessionId: "s1") }
        XCTAssertEqual(appState.sessions["s1"]?.recap?.text, "Old recap")

        try await Task.sleep(nanoseconds: 150_000_000)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(prompt[cut...]).utf8))
        try handle.close()

        var attempts = 0
        while appState.sessions["s1"]?.recap != nil, attempts < 150 {
            attempts += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(appState.sessions["s1"]?.recap)
        XCTAssertEqual(appState.sessions["s1"]?.lastUserPrompt, "typed right as the island attached")
    }

    // MARK: - Persistence

    func testPersistedSessionRoundTripsRecapAndEffort() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-12T03:35:41Z"))
        let session = PersistedSession(
            sessionId: "s1", cwd: "/repo", source: "claude", model: "claude-opus-5-5",
            sessionTitle: nil, sessionTitleSource: nil, providerSessionId: nil,
            lastUserPrompt: "hi", lastAssistantMessage: "done",
            termApp: nil, itermSessionId: nil, ttyPath: nil, kittyWindowId: nil,
            tmuxPane: nil, tmuxClientTty: nil, tmuxEnv: nil, termBundleId: nil,
            cmuxSurfaceId: nil, cmuxWorkspaceId: nil, zellijPaneId: nil, zellijSessionName: nil,
            weztermPaneId: nil, herdrPaneId: nil, herdrSocketPath: nil, herdrBinaryPath: nil,
            cliPid: nil, cliStartTime: nil, startTime: createdAt, lastActivity: createdAt,
            transcriptPath: nil, closedSubagentIds: nil,
            recap: SessionRecap(text: "Recap text", createdAt: createdAt),
            reasoningEffort: "xhigh"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(PersistedSession.self, from: encoder.encode(session))

        XCTAssertEqual(decoded.recap, SessionRecap(text: "Recap text", createdAt: createdAt))
        XCTAssertEqual(decoded.reasoningEffort, "xhigh")
    }

    func testPersistedSessionWithoutRecapFieldsStillDecodes() throws {
        let json = """
        {"sessionId":"s1","source":"claude","startTime":"2026-04-09T10:00:00Z","lastActivity":"2026-04-09T10:01:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedSession.self, from: Data(json.utf8))
        XCTAssertNil(decoded.recap)
        XCTAssertNil(decoded.reasoningEffort)
    }
}
