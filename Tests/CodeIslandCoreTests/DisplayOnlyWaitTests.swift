import XCTest
@testable import CodeIslandCore

/// Display-only waits in the follow-up scheduler: entries that come from a
/// session's waiting status rather than the island's queues, reconciled on
/// their own and carrying their origin into every reminder.
final class DisplayOnlyWaitSchedulerTests: XCTestCase {
    typealias Key = FollowUpReminderScheduler.Key

    private let t0 = Date(timeIntervalSinceReferenceDate: 20_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testDisplayOnlyEntriesCarryTheirOriginIntoEveryDelivery() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: ["cowork"], now: t0)
        XCTAssertEqual(scheduler.origin(of: Key(.approval, "cowork")), .displayOnly)

        XCTAssertEqual(scheduler.collectDue(now: at(60), heldBack: true).map(\.origin), [.displayOnly])
        let caughtUp = scheduler.collectDue(now: at(70), heldBack: false)
        XCTAssertEqual(caughtUp, [FollowUpReminder(
            kind: .approval, sessionId: "cowork", attempt: 1, maxAttempts: 3,
            waitingSince: t0, delivery: .catchUp, origin: .displayOnly
        )])
    }

    func testDisplayOnlyWaitsRemindThreeTimesLikeQueuedOnes() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .question, origin: .displayOnly, waiting: ["cursor"], now: t0)
        let attempts = (1...5).flatMap { scheduler.collectDue(now: at(Double($0) * 60), heldBack: false) }
        XCTAssertEqual(attempts.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(attempts.last?.isFinal, true)
    }

    func testEachOriginIsReconciledOnItsOwn() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, waiting: ["queued"], now: t0)
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: ["cowork"], now: t0)

        // The queue empties: only the island's entry goes.
        scheduler.sync(kind: .approval, waiting: [], now: at(1))
        XCTAssertEqual(scheduler.trackedKeys, [Key(.approval, "cowork")])

        // The display-only wait ends: its entry goes too.
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: [], now: at(2))
        XCTAssertTrue(scheduler.isEmpty)
    }

    /// A terminal permission prompt the island then queues is the same wait:
    /// timing and attempts carry over, and it now counts as the island's.
    func testQueueingAWaitAdoptsItsDisplayOnlyEntry() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: ["term"], now: t0)
        XCTAssertEqual(scheduler.collectDue(now: at(60), heldBack: false).map(\.attempt), [1])

        scheduler.sync(kind: .approval, waiting: ["term"], now: at(90))
        XCTAssertEqual(scheduler.origin(of: Key(.approval, "term")), .island)
        let next = scheduler.collectDue(now: at(120), heldBack: false)
        XCTAssertEqual(next.map(\.attempt), [2])
        XCTAssertEqual(next.first?.waitingSince, t0)
        XCTAssertEqual(next.first?.origin, .island)

        // A display-only sync no longer owns it.
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: [], now: at(121))
        XCTAssertEqual(scheduler.trackedKeys, [Key(.approval, "term")])
    }

    func testSilencedWaitStaysSilentUntilANewOneRestartsIt() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: ["s"], now: t0)
        scheduler.silence(Key(.approval, "s"))
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: ["s"], now: at(30))
        XCTAssertEqual(scheduler.collectDue(now: at(600), heldBack: false), [], "same wait, still silenced")

        scheduler.restart(kind: .approval, sessionId: "s", origin: .displayOnly, now: at(700))
        XCTAssertEqual(scheduler.nextWakeDate(), at(760))
        let fired = scheduler.collectDue(now: at(760), heldBack: false)
        XCTAssertEqual(fired.map(\.attempt), [1])
        XCTAssertEqual(fired.first?.waitingSince, at(700))
    }

    func testRestartRetimesAWaitStillCounting() {
        var scheduler = FollowUpReminderScheduler(interval: 60)
        scheduler.sync(kind: .question, origin: .displayOnly, waiting: ["s"], now: t0)
        _ = scheduler.collectDue(now: at(60), heldBack: false)
        scheduler.restart(kind: .question, sessionId: "s", origin: .displayOnly, now: at(100))
        XCTAssertEqual(scheduler.collectDue(now: at(160), heldBack: false).map(\.attempt), [1])
    }

    func testOffKeepsNothing() {
        var scheduler = FollowUpReminderScheduler(interval: nil)
        scheduler.sync(kind: .approval, origin: .displayOnly, waiting: ["s"], now: t0)
        scheduler.restart(kind: .approval, sessionId: "s", origin: .displayOnly, now: t0)
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testReminderDefaultsToTheIslandOrigin() {
        let reminder = FollowUpReminder(
            kind: .completion, sessionId: "c", attempt: 1, maxAttempts: 1, waitingSince: t0, delivery: .onTime
        )
        XCTAssertEqual(reminder.origin, .island)
    }
}

/// What counts as a display-only wait, where it is answered and what it asks.
final class DisplayOnlyWaitTests: XCTestCase {
    private func session(
        status: AgentStatus,
        source: String? = nil,
        termBundleId: String? = nil,
        termApp: String? = nil
    ) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.status = status
        if let source { session.source = source }
        session.termBundleId = termBundleId
        session.termApp = termApp
        return session
    }

    // MARK: Classification

    func testWaitingStatusWithoutAnIslandRequestIsDisplayOnly() {
        XCTAssertEqual(DisplayOnlyWait.kind(status: .waitingApproval, islandHoldsRequest: false), .approval)
        XCTAssertEqual(DisplayOnlyWait.kind(status: .waitingQuestion, islandHoldsRequest: false), .question)
    }

    func testARequestTheIslandHoldsIsNeverDisplayOnly() {
        XCTAssertNil(DisplayOnlyWait.kind(status: .waitingApproval, islandHoldsRequest: true))
        XCTAssertNil(DisplayOnlyWait.kind(status: .waitingQuestion, islandHoldsRequest: true))
    }

    func testWorkingOrIdleSessionsAreNotWaiting() {
        for status in [AgentStatus.idle, .processing, .running] {
            XCTAssertNil(DisplayOnlyWait.kind(status: status, islandHoldsRequest: false), "\(status)")
        }
    }

    func testSessionIdsPerKind() {
        let sessions = [
            "cowork": session(status: .waitingApproval),
            "cursor": session(status: .waitingQuestion),
            "queued": session(status: .waitingApproval),
            "busy": session(status: .running),
        ]
        XCTAssertEqual(
            DisplayOnlyWait.sessionIds(waitingOn: .approval, in: sessions, islandRequestSessionIds: ["queued"]),
            ["cowork"]
        )
        XCTAssertEqual(
            DisplayOnlyWait.sessionIds(waitingOn: .question, in: sessions, islandRequestSessionIds: ["queued"]),
            ["cursor"]
        )
    }

    // MARK: Where to answer

    func testAnswerPlaceNamesTheHostApp() {
        XCTAssertEqual(
            DisplayOnlyWait.answerPlace(for: session(
                status: .waitingApproval, source: "claude", termBundleId: "com.anthropic.claudefordesktop", termApp: "Claude"
            )),
            "Claude Desktop",
            "the card badge's \"Claude\" would read as the model on a phone"
        )
        XCTAssertEqual(
            DisplayOnlyWait.answerPlace(for: session(
                status: .waitingQuestion, source: "cursor", termBundleId: "com.todesktop.230313mzl4w4u92"
            )),
            "Cursor"
        )
        XCTAssertEqual(DisplayOnlyWait.answerPlace(for: session(status: .waitingApproval, source: "aiwork")), "AiWork")
        XCTAssertEqual(DisplayOnlyWait.answerPlace(for: session(status: .waitingApproval, termApp: "iTerm.app")), "iTerm2")
    }

    func testAnswerPlaceIsUnknownForRemoteOrBareSessions() {
        var remote = session(status: .waitingApproval, termApp: "iTerm.app")
        remote.remoteHostId = "devbox"
        remote.remoteHostName = "devbox"
        XCTAssertNil(DisplayOnlyWait.answerPlace(for: remote))
        XCTAssertNil(DisplayOnlyWait.answerPlace(for: session(status: .waitingApproval)))
    }

    // MARK: What is asked

    func testFallbackNeverGuessesFromTheCardsToolFields() {
        var stale = session(status: .waitingApproval)
        stale.currentTool = "Read"
        stale.toolDescription = "README.md"
        XCTAssertEqual(
            DisplayOnlyWait.fallbackContent(kind: .approval, session: stale),
            .permission(tool: nil, detail: nil)
        )
        XCTAssertEqual(
            DisplayOnlyWait.fallbackContent(kind: .question, session: stale),
            .question(items: [], isSecret: false)
        )
    }

    func testFallbackUsesCursorsPendingQuestion() {
        var cursor = session(status: .waitingQuestion, source: "cursor")
        cursor.cursorPendingQuestion = "  Which DB?  "
        XCTAssertEqual(
            DisplayOnlyWait.fallbackContent(kind: .question, session: cursor),
            .question(items: [PushQuestionItem(question: "Which DB?")], isSecret: false)
        )
    }

    func testCoworkContentIsTheCardOnTop() {
        var audit = CoworkAuditState()
        audit.apply([
            .userPrompt(text: "clean up", isSynthetic: false),
            .permissionRequested(id: "1", toolName: "Read", detail: "notes.md"),
            .permissionRequested(id: "2", toolName: "Bash", detail: "rm -rf build"),
        ])
        XCTAssertEqual(DisplayOnlyWait.content(forCowork: audit), .permission(tool: "Bash", detail: "rm -rf build"))

        audit.apply(.permissionRequested(id: "3", toolName: "AskUserQuestion", detail: "Which folder?"))
        XCTAssertEqual(
            DisplayOnlyWait.content(forCowork: audit),
            .question(items: [PushQuestionItem(question: "Which folder?")], isSecret: false)
        )

        audit.apply(.turnEnded(isError: false, resultText: "done"))
        XCTAssertNil(DisplayOnlyWait.content(forCowork: audit))
    }

    func testAiWorkContentComesFromTheEvent() {
        XCTAssertEqual(
            DisplayOnlyWait.content(
                forAiWorkEvent: "stream.approval_required",
                data: ["tool_name": .string("shell"), "command": .string("git push --force")]
            ),
            .permission(tool: "shell", detail: "git push --force")
        )
        XCTAssertEqual(
            DisplayOnlyWait.content(forAiWorkEvent: "stream.plan_confirmation_required", data: ["reason": .string("3-step plan")]),
            .permission(tool: nil, detail: "3-step plan")
        )
        XCTAssertEqual(
            DisplayOnlyWait.content(forAiWorkEvent: "stream.question_required", data: ["message": .string("Deploy now?")]),
            .question(items: [PushQuestionItem(question: "Deploy now?")], isSecret: false)
        )
        XCTAssertNil(DisplayOnlyWait.content(forAiWorkEvent: "stream.text_delta", data: ["text": .string("hi")]))
    }
}

/// How a display-only wait reads on a phone: what is asked, then where to
/// answer it — never as if the phone could.
final class DisplayOnlyWaitPushFormatTests: XCTestCase {
    private let subject = PushSubject(sessionId: "s1", agent: "Claude", project: "app")
    private let strings = PushStrings.english

    private func render(_ content: PushContent, now: Date = Date()) -> PushMessage {
        PushMessageFormatter.render(content, subject: subject, strings: strings, now: now)
    }

    func testApprovalSaysWhereToRespond() {
        let message = render(.answerElsewhere(pending: .permission(tool: "Bash", detail: "rm x"), app: "Claude Desktop"))
        XCTAssertEqual(message.kind, .permission, "channel checkboxes and dedupe treat it as an approval")
        XCTAssertTrue(message.blocksAgent)
        XCTAssertEqual(message.title, "🔐 Claude · app")
        XCTAssertEqual(message.headline, "Needs approval: Bash")
        XCTAssertEqual(message.body, "rm x\nRespond in Claude Desktop.")
    }

    func testQuestionWithoutTextStillSaysWhoAndWhere() {
        let message = render(.answerElsewhere(pending: .question(items: [], isSecret: false), app: "Cursor"))
        XCTAssertEqual(message.kind, .question)
        XCTAssertEqual(message.headline, "Has a question")
        XCTAssertEqual(message.body, "Respond in Cursor.")
    }

    func testUnknownAppFallsBackToTheMac() {
        let message = render(.answerElsewhere(pending: .permission(tool: nil, detail: nil), app: "  "))
        XCTAssertEqual(message.headline, "Needs approval")
        XCTAssertEqual(message.body, "Respond on your Mac.")
    }

    func testReminderRepeatsTheAskAndTheApp() {
        let now = Date(timeIntervalSince1970: 50_000)
        let message = render(
            .reminder(
                pending: .answerElsewhere(
                    pending: .question(items: [PushQuestionItem(question: "Which DB?", options: ["Postgres"])], isSecret: false),
                    app: "Cursor"
                ),
                waitingSince: now.addingTimeInterval(-3 * 60)
            ),
            now: now
        )
        XCTAssertEqual(message.kind, .reminder)
        XCTAssertTrue(message.blocksAgent)
        XCTAssertEqual(message.headline, "Still waiting · 3 min")
        XCTAssertEqual(message.body, "Has a question\nWhich DB?\n1. Postgres\nRespond in Cursor.")
    }
}
