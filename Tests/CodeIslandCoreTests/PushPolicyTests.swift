import XCTest
@testable import CodeIslandCore

/// "Am I away", the send gate, dedupe, and which hook events count as a
/// session error or a subagent completion.
final class PushPolicyTests: XCTestCase {

    // MARK: Presence

    func testAwayWhenScreenIsOffOrLockedRegardlessOfIdleTime() {
        let fresh = PushPresenceSnapshot(idleSeconds: 1)
        XCTAssertFalse(fresh.isAway(idleThreshold: 300))
        for snapshot in [
            PushPresenceSnapshot(screenLocked: true, idleSeconds: 1),
            PushPresenceSnapshot(screenSaverRunning: true, idleSeconds: 1),
            PushPresenceSnapshot(displaysAsleep: true, idleSeconds: 1),
            PushPresenceSnapshot(sessionOnConsole: false, idleSeconds: 1),
        ] {
            XCTAssertTrue(snapshot.isAway(idleThreshold: 300), "\(snapshot)")
        }
    }

    func testAwayAfterIdleThreshold() {
        XCTAssertFalse(PushPresenceSnapshot(idleSeconds: 299).isAway(idleThreshold: 300))
        XCTAssertTrue(PushPresenceSnapshot(idleSeconds: 300).isAway(idleThreshold: 300))
    }

    // MARK: Gate

    private let present = PushPresenceSnapshot(idleSeconds: 5)
    private let away = PushPresenceSnapshot(screenLocked: true)

    private func gate(
        _ kind: PushEventKind,
        onlyWhenAway: Bool = true,
        presence: PushPresenceSnapshot,
        smartSuppressed: Bool = false,
        isSubagent: Bool = false,
        interrupted: Bool = false
    ) -> PushSkipReason? {
        PushGate.evaluate(PushGateInput(
            kind: kind,
            onlyWhenAway: onlyWhenAway,
            idleThreshold: 300,
            presence: presence,
            smartSuppressed: smartSuppressed,
            isSubagent: isSubagent,
            interrupted: interrupted
        ))
    }

    func testOnlyWhenAwayHoldsBackWhileThePersonIsAtTheMac() {
        XCTAssertEqual(gate(.permission, presence: present), .userPresent)
        XCTAssertNil(gate(.permission, presence: away))
        XCTAssertNil(gate(.permission, onlyWhenAway: false, presence: present))
    }

    func testSmartSuppressOnlyCountsWhileThePersonIsPresent() {
        XCTAssertEqual(gate(.completion, onlyWhenAway: false, presence: present, smartSuppressed: true), .smartSuppressed)
        // A locked Mac still reports the terminal as frontmost; that must not
        // swallow the push the user left the desk to receive.
        XCTAssertNil(gate(.completion, onlyWhenAway: false, presence: away, smartSuppressed: true))
        XCTAssertNil(gate(.permission, presence: away, smartSuppressed: true))
    }

    func testSubagentAndInterruptedTurnsNeverPushACompletion() {
        XCTAssertEqual(gate(.completion, presence: away, isSubagent: true), .subagent)
        XCTAssertEqual(gate(.completion, presence: away, interrupted: true), .interrupted)
        // A subagent's approval still blocks the work, so it is pushed.
        XCTAssertNil(gate(.permission, presence: away, isSubagent: true))
    }

    // MARK: Dedupe

    func testSameSessionSameKindCollapsesWithinTheWindow() {
        var dedupe = PushDeduplicator(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "a", now: t0))
        XCTAssertEqual(dedupe.admit(kind: .permission, sessionId: "a", now: t0.addingTimeInterval(10)), .duplicate)
        XCTAssertNil(dedupe.admit(kind: .question, sessionId: "a", now: t0.addingTimeInterval(11)), "other kind")
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "b", now: t0.addingTimeInterval(12)), "other session")
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "a", now: t0.addingTimeInterval(61)), "window over")
    }

    func testApprovalsAndQuestionsAreDedupedPerRequestUntilAnswered() {
        var dedupe = PushDeduplicator(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "a", requestKey: "id:1", now: t0))
        XCTAssertEqual(dedupe.admit(kind: .permission, sessionId: "a", requestKey: "id:1", now: t0.addingTimeInterval(5)), .duplicate, "a replay")
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "a", requestKey: "id:2", now: t0.addingTimeInterval(6)), "another request")

        dedupe.forget(kind: .permission, sessionId: "a", requestKey: "id:1")
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "a", requestKey: "id:1", now: t0.addingTimeInterval(7)), "answered, then asked again")
        XCTAssertEqual(dedupe.admit(kind: .permission, sessionId: "a", requestKey: "id:2", now: t0.addingTimeInterval(8)), .duplicate)
    }

    func testSkippedPushesDoNotStartAWindow() {
        var dedupe = PushDeduplicator(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(dedupe.admit(kind: .completion, sessionId: "a", now: t0))
        XCTAssertEqual(dedupe.admit(kind: .completion, sessionId: "a", now: t0.addingTimeInterval(30)), .duplicate)
        // The rejected attempt at +30 must not push the window to +90.
        XCTAssertNil(dedupe.admit(kind: .completion, sessionId: "a", now: t0.addingTimeInterval(61)))
    }

    func testCompletionRightAfterAnErrorIsTheSameTurnEnding() {
        var dedupe = PushDeduplicator(window: 60, errorShadow: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(dedupe.admit(kind: .error, sessionId: "a", now: t0))
        XCTAssertEqual(dedupe.admit(kind: .completion, sessionId: "a", now: t0.addingTimeInterval(1)), .duplicate)
        XCTAssertNil(dedupe.admit(kind: .completion, sessionId: "b", now: t0.addingTimeInterval(2)))
    }

    func testLastSentIsRememberedBeyondTheDedupeWindow() {
        var dedupe = PushDeduplicator(window: 60, memory: 3_600)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(dedupe.admit(kind: .completion, sessionId: "a", now: t0))
        // Other traffic prunes the tables; the completion is still remembered.
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "b", now: t0.addingTimeInterval(600)))
        XCTAssertEqual(dedupe.lastSent(kind: .completion, sessionId: "a"), t0)
        XCTAssertNil(dedupe.admit(kind: .permission, sessionId: "c", now: t0.addingTimeInterval(3_700)))
        XCTAssertNil(dedupe.lastSent(kind: .completion, sessionId: "a"), "forgotten after `memory`")
    }

    // MARK: Rate limits

    func testRateLimiterFindsTheNextFreeSlotAcrossWindows() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var limiter = PushRateLimiter(windows: [PushRateWindow(count: 3, seconds: 60)])
        for i in 0..<3 {
            let at = t0.addingTimeInterval(Double(i))
            XCTAssertEqual(limiter.nextSlot(now: at), at)
            limiter.record(at)
        }
        let now = t0.addingTimeInterval(5)
        XCTAssertEqual(limiter.nextSlot(now: now), t0.addingTimeInterval(60), "room once the oldest ages out")
        XCTAssertEqual(limiter.nextSlot(now: t0.addingTimeInterval(61)), t0.addingTimeInterval(61))

        var perSecond = PushRateLimiter(windows: [PushRateWindow(count: 5, seconds: 60), PushRateWindow(count: 1, seconds: 1)])
        perSecond.record(t0)
        XCTAssertEqual(perSecond.nextSlot(now: t0.addingTimeInterval(0.2)), t0.addingTimeInterval(1))
        XCTAssertEqual(PushRateLimiter(windows: []).nextSlot(now: t0), t0, "no limit")
    }

    func testOnlyTeamChatsAreThrottledAndApprovalsMustBeDelivered() {
        for kind in PushChannelKind.allCases {
            XCTAssertEqual(!kind.rateLimits.isEmpty, kind.isGroupChat, kind.rawValue)
        }
        // Under the documented 20 / min, so the robot is never silenced.
        XCTAssertLessThan(PushChannelKind.dingtalk.rateLimits[0].count, 20)
        XCTAssertLessThan(PushChannelKind.wecom.rateLimits[0].count, 20)
        XCTAssertTrue(PushThrottle.mustDeliver(.permission))
        XCTAssertTrue(PushThrottle.mustDeliver(.question))
        for kind in [PushEventKind.completion, .error, .reminder] {
            XCTAssertFalse(PushThrottle.mustDeliver(kind))
        }
    }

    // MARK: Classification

    func testClaudeAndGrokStopFailureIsASessionError() {
        let raw: [String: Any] = [
            "hook_event_name": "StopFailure",
            "error": "rate_limit",
            "error_details": "429 Too Many Requests",
            "last_assistant_message": "API Error: Rate limit reached",
        ]
        XCTAssertEqual(
            PushEventClassifier.sessionError(eventName: "StopFailure", raw: raw),
            PushSessionError(type: "rate_limit", detail: "API Error: Rate limit reached")
        )
        XCTAssertEqual(
            PushEventClassifier.sessionError(eventName: "stop_failure", raw: ["error": "server_error", "error_details": "500"]),
            PushSessionError(type: "server_error", detail: "500")
        )
    }

    func testCopilotErrorOccurredUnlessRecoverable() {
        let error: [String: Any] = ["message": "Model call failed", "name": "APIError"]
        XCTAssertEqual(
            PushEventClassifier.sessionError(eventName: "errorOccurred", raw: ["error": error, "recoverable": false]),
            PushSessionError(type: "APIError", detail: "Model call failed")
        )
        XCTAssertNil(PushEventClassifier.sessionError(eventName: "errorOccurred", raw: ["error": error, "recoverable": true]))
        XCTAssertNotNil(PushEventClassifier.sessionError(eventName: "ErrorOccurred", raw: ["error": error]))
    }

    func testOrdinaryEventsAreNotErrors() {
        for name in ["Stop", "PostToolUseFailure", "Notification", "SessionEnd"] {
            XCTAssertNil(PushEventClassifier.sessionError(eventName: name, raw: ["error": "x"]), name)
        }
    }

    func testSubagentCompletionDetection() {
        XCTAssertTrue(PushEventClassifier.isSubagentCompletion(agentId: "agent-1", raw: [:], sessionId: "s", session: nil))
        XCTAssertFalse(PushEventClassifier.isSubagentCompletion(agentId: nil, raw: [:], sessionId: "s", session: SessionSnapshot()))

        var cursorTask = SessionSnapshot()
        cursorTask.source = "cursor"
        cursorTask.transcriptPath = "/Users/me/.cursor/projects/p/agent-transcripts/parent-id/subagents/child-id.jsonl"
        let isTask = CursorSubsessionRouter.isLikelyCursorTaskCard(
            sessionId: "child-id",
            providerSessionId: nil,
            transcriptPath: cursorTask.transcriptPath
        )
        XCTAssertEqual(
            PushEventClassifier.isSubagentCompletion(agentId: nil, raw: [:], sessionId: "child-id", session: cursorTask),
            isTask,
            "delegates to the same Task-card test the router uses"
        )
    }
}

/// Rendering of structured content into title / headline / body.
final class PushMessageFormatterTests: XCTestCase {
    private let subject = PushSubject(sessionId: "s1", agent: "Claude", project: "vibe-notch")
    private let strings = PushStrings.english

    private func render(_ content: PushContent, subject: PushSubject? = nil, limit: Int = 200, now: Date = Date()) -> PushMessage {
        PushMessageFormatter.render(content, subject: subject ?? self.subject, strings: strings, summaryLimit: limit, now: now)
    }

    func testPermissionShowsAgentProjectToolAndCommand() {
        let message = render(.permission(tool: "Bash", detail: "swift build"))
        XCTAssertEqual(message.kind, .permission)
        XCTAssertEqual(message.title, "🔐 Claude · vibe-notch")
        XCTAssertEqual(message.headline, "Needs approval: Bash")
        XCTAssertEqual(message.body, "swift build")
        XCTAssertEqual(message.text, "Needs approval: Bash\nswift build")
    }

    func testRemoteSessionsNameTheirHost() {
        let remote = PushSubject(sessionId: "r", agent: "Codex", project: "api", host: "devbox")
        XCTAssertEqual(render(.completion(summary: nil), subject: remote).title, "✅ Codex · api @ devbox")
        XCTAssertEqual(PushSubject(sessionId: "x", agent: "Claude").label, "Claude")
    }

    func testCredentialsInCommandsAreRedactedBeforeLeavingTheMac() {
        let message = render(.permission(
            tool: "Bash",
            detail: "curl -H 'Authorization: Bearer abcdef123456' https://api.example.com --token s3cr3t"
        ))
        XCTAssertFalse(message.body.contains("abcdef123456"), message.body)
        XCTAssertFalse(message.body.contains("s3cr3t"), message.body)
        XCTAssertTrue(message.body.contains("[REDACTED]"))
    }

    /// A heredoc's body is a file's contents, a script or a key: only the
    /// command's first line leaves the Mac, with a mark that more followed.
    func testPermissionDetailSendsOnlyTheCommandsFirstLine() {
        let message = render(.permission(
            tool: "Bash",
            detail: "\ncat > .env <<'EOF'\nDB_URL=postgres://app@db/app\nSTRIPE=hunter2\nEOF"
        ))
        XCTAssertEqual(message.body, "cat > .env <<'EOF' …")
        XCTAssertFalse(message.text.contains("hunter2"))
        XCTAssertEqual(render(.permission(tool: "Bash", detail: "swift build\n  \n")).body, "swift build")
    }

    /// Team chats get who, where and what happened — never the command,
    /// reply, error text or answer options.
    func testHeadlineOnlyRenderingLeavesEveryDetailOut() {
        func brief(_ content: PushContent) -> PushMessage {
            PushMessageFormatter.render(content, subject: subject, strings: strings, includeDetails: false)
        }
        let permission = brief(.permission(tool: "Bash", detail: "rm -rf build"))
        XCTAssertEqual(permission.title, "🔐 Claude · vibe-notch")
        XCTAssertEqual(permission.headline, "Needs approval: Bash")
        XCTAssertEqual(permission.body, "")

        let question = brief(.question(
            items: [
                PushQuestionItem(question: "Which database password?", options: ["hunter2", "letmein"], header: "DB"),
                PushQuestionItem(question: "Deploy?", options: ["Yes", "No"], header: "Deploy"),
            ],
            isSecret: false
        ))
        XCTAssertEqual(question.headline, "Has a question: DB · Deploy")
        XCTAssertEqual(question.body, "")
        XCTAssertEqual(brief(.question(items: [PushQuestionItem(question: "Why?")], isSecret: false)).text, "Has a question")

        XCTAssertEqual(brief(.completion(summary: "Pushed the fix to prod.")).text, "Finished")
        XCTAssertEqual(brief(.error(type: "rate_limit", detail: "API Error: quota for org-123")).text, "Stopped on an error (rate_limit)")

        let reminder = brief(.reminder(pending: .permission(tool: "Bash", detail: "make deploy"), waitingSince: nil))
        XCTAssertEqual(reminder.body, "Needs approval: Bash")

        let elsewhere = brief(.answerElsewhere(pending: .permission(tool: "Bash", detail: "ls ~/secret"), app: "Claude Desktop"))
        XCTAssertEqual(elsewhere.body, "Respond in Claude Desktop.")
    }

    func testCommandsKeepTheirGlobsAndBackticks() {
        let message = render(.permission(tool: "Bash", detail: "rm **/*.tmp && echo `date`"))
        XCTAssertEqual(message.body, "rm **/*.tmp && echo `date`")
    }

    func testQuestionOptionsAreNumbered() {
        let message = render(.question(
            items: [PushQuestionItem(question: "Which database?", options: ["Postgres", "SQLite"])],
            isSecret: false
        ))
        XCTAssertEqual(message.headline, "Has a question")
        XCTAssertEqual(message.body, "Which database?\n1. Postgres\n2. SQLite")
    }

    func testMultiQuestionWizardsArePrefixedAndLongListsCut() {
        let many = (1...12).map { "Option \($0)" }
        let message = render(.question(
            items: [
                PushQuestionItem(question: "First?", options: ["A", "B"]),
                PushQuestionItem(question: "Second?", options: many),
            ],
            isSecret: false
        ))
        let lines = message.body.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "(1/2) First?")
        XCTAssertEqual(lines[1], "1. A")
        XCTAssertEqual(lines[3], "(2/2) Second?")
        XCTAssertEqual(lines[4 + PushMessageFormatter.maxOptions - 1], "9. Option 9")
        XCTAssertEqual(lines.last, "+3 more")
    }

    func testSecretQuestionsNeverLeaveTheMac() {
        let message = render(.question(
            items: [PushQuestionItem(question: "Paste your API key", options: ["sk-live-123"])],
            isSecret: true
        ))
        XCTAssertEqual(message.body, strings.secretQuestion)
        XCTAssertFalse(message.text.contains("API key"))
    }

    func testCompletionSummaryDropsMarkdownAndIsTruncated() {
        let reply = """
        ## Done
        **All** tests pass. Run `swift test` again with:
        ```bash
        swift test
        ```
        """
        let message = render(.completion(summary: reply), limit: 40)
        XCTAssertEqual(message.headline, "Finished")
        XCTAssertFalse(message.body.contains("**"))
        XCTAssertFalse(message.body.contains("```"))
        XCTAssertTrue(message.body.hasPrefix("Done\nAll tests pass."))
        XCTAssertLessThanOrEqual(message.body.count, 40)
        XCTAssertTrue(message.body.hasSuffix("…"))
    }

    func testErrorHeadlineCarriesTheErrorClass() {
        let message = render(.error(type: "rate_limit", detail: "API Error: Rate limit reached"))
        XCTAssertEqual(message.title, "❌ Claude · vibe-notch")
        XCTAssertEqual(message.headline, "Stopped on an error (rate_limit)")
        XCTAssertEqual(message.body, "API Error: Rate limit reached")
    }

    func testReminderRepeatsWhatIsWaitingAndForHowLong() {
        let now = Date(timeIntervalSince1970: 10_000)
        let message = render(
            .reminder(pending: .permission(tool: "Bash", detail: "make deploy"), waitingSince: now.addingTimeInterval(-7 * 60 - 5)),
            now: now
        )
        XCTAssertEqual(message.kind, .reminder)
        XCTAssertEqual(message.title, "⏰ Claude · vibe-notch")
        XCTAssertEqual(message.headline, "Still waiting · 7 min")
        XCTAssertEqual(message.body, "Needs approval: Bash\nmake deploy")

        let bare = render(.reminder(pending: nil, waitingSince: now.addingTimeInterval(-20)), now: now)
        XCTAssertEqual(bare.headline, "Still waiting", "under a minute shows no duration")
        XCTAssertEqual(bare.body, "")
    }

    func testReminderUrgencyFollowsWhatItRemindsAbout() {
        XCTAssertTrue(render(.reminder(pending: .question(items: [], isSecret: false), waitingSince: nil)).blocksAgent)
        XCTAssertFalse(render(.reminder(pending: .completion(summary: "done"), waitingSince: nil)).blocksAgent)
        XCTAssertFalse(render(.error(type: nil, detail: nil)).blocksAgent)
        XCTAssertTrue(render(.permission(tool: nil, detail: nil)).blocksAgent)
    }

    /// A huge reply is cut on a line boundary before the redaction pass, not
    /// after it; what survives is still redacted and bounded.
    func testLongRepliesArePrecutBeforeRedaction() {
        let line = "token=abc123 " + String(repeating: "word ", count: 20)
        let reply = Array(repeating: line, count: 5_000).joined(separator: "\n")
        let cut = PushMessageFormatter.precut(reply, keeping: 200)
        XCTAssertLessThanOrEqual(cut.utf16.count, 200 * 2 + 256)
        XCTAssertTrue(reply.hasPrefix(cut))
        XCTAssertTrue(cut.hasSuffix(line.trimmingCharacters(in: .whitespaces)) || cut.hasSuffix(line), "ends on a whole line")

        let message = render(.completion(summary: reply), limit: 200)
        XCTAssertLessThanOrEqual(message.body.count, 200)
        XCTAssertFalse(message.body.contains("abc123"))
        XCTAssertEqual(PushMessageFormatter.precut("short\ntext", keeping: 10), "short\ntext")

        // One enormous line is cut at a word boundary, never inside a word.
        let oneLine = String(repeating: "abcdefghij ", count: 200)
        let cutLine = PushMessageFormatter.precut(oneLine, keeping: 100)
        XCTAssertTrue(cutLine.hasSuffix("abcdefghij"))
    }

    func testUTF16TruncationNeverSplitsACharacter() {
        let family = "👨‍👩‍👧"  // 8 UTF-16 units, one character
        let text = String(repeating: family, count: 5)
        let cut = PushMessageFormatter.truncated(text, maxUTF16: 20)
        XCTAssertLessThanOrEqual(cut.utf16.count, 20)
        XCTAssertEqual(cut, family + family + "…")
        XCTAssertEqual(PushMessageFormatter.truncated("abc", maxUTF16: 5), "abc")
    }

    func testByteTruncationNeverSplitsACharacter() {
        let text = String(repeating: "界", count: 10)  // 30 bytes
        let cut = PushMessageFormatter.truncated(text, maxUTF8Bytes: 10)
        XCTAssertLessThanOrEqual(cut.utf8.count, 10)
        XCTAssertEqual(cut, "界界…")
        XCTAssertEqual(PushMessageFormatter.truncated("short", maxUTF8Bytes: 10), "short")
        XCTAssertEqual(PushMessageFormatter.truncated("abcdef", limit: 4), "abc…")
    }

    // MARK: Permission detail

    func testDetailPrefersCommandThenProjectRelativePath() {
        XCTAssertEqual(
            PushDetailSummarizer.permissionDetail(toolInput: ["command": "ls -la", "description": "List"], fallback: "x", cwd: nil),
            "ls -la"
        )
        XCTAssertEqual(
            PushDetailSummarizer.permissionDetail(toolInput: ["command": ["bash", "-lc", "make test"]], fallback: nil, cwd: nil),
            "bash -lc make test",
            "Codex passes argv"
        )
        XCTAssertEqual(
            PushDetailSummarizer.permissionDetail(
                toolInput: ["file_path": "/Users/me/code/app/Sources/Main.swift"],
                fallback: "Main.swift",
                cwd: "/Users/me/code/app"
            ),
            "Sources/Main.swift"
        )
        XCTAssertEqual(
            PushDetailSummarizer.permissionDetail(toolInput: ["file_path": "/etc/hosts"], fallback: nil, cwd: "/Users/me/code/app"),
            "/etc/hosts"
        )
        XCTAssertEqual(
            PushDetailSummarizer.permissionDetail(toolInput: ["url": "https://example.com/docs"], fallback: nil, cwd: nil),
            "https://example.com/docs"
        )
        XCTAssertEqual(PushDetailSummarizer.permissionDetail(toolInput: [:], fallback: " fallback ", cwd: nil), "fallback")
        XCTAssertNil(PushDetailSummarizer.permissionDetail(toolInput: nil, fallback: nil, cwd: nil))
    }

    func testTestMessageUsesTheUrgentStyle() {
        let message = PushMessage.test(strings: strings)
        XCTAssertTrue(message.kind.blocksAgent)
        XCTAssertEqual(message.headline, "Test notification")
    }
}
