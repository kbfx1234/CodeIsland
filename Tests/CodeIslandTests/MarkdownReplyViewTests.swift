import XCTest
import SwiftUI
@testable import CodeIsland
import CodeIslandCore

final class MarkdownReplyViewTests: XCTestCase {
    // MARK: - List markers

    func testOrderedMarkersArePaddedToTheWidestNumber() {
        let list = MarkdownList(isOrdered: true, start: 9, items: Array(repeating: MarkdownListItem(blocks: []), count: 3))
        XCTAssertEqual(MarkdownListMarker.markers(for: list, depth: 0).map(\.label), [" 9.", "10.", "11."])
    }

    func testBulletGlyphFollowsNestingDepth() {
        let list = MarkdownList(isOrdered: false, start: 1, items: [MarkdownListItem(blocks: [])])
        let glyphs = (0..<4).map { MarkdownListMarker.markers(for: list, depth: $0).first?.label }
        XCTAssertEqual(glyphs, ["•", "◦", "▪", "•"])
    }

    func testCheckboxReplacesTheBulletButNotTheNumber() {
        let items = [MarkdownListItem(checkbox: .checked, blocks: []), MarkdownListItem(blocks: [])]
        let bullets = MarkdownListMarker.markers(for: MarkdownList(isOrdered: false, start: 1, items: items), depth: 0)
        XCTAssertEqual(bullets[0], MarkdownListMarker(label: nil, checkbox: .checked))
        XCTAssertEqual(bullets[1], MarkdownListMarker(label: "•", checkbox: nil))

        let ordered = MarkdownListMarker.markers(for: MarkdownList(isOrdered: true, start: 1, items: items), depth: 0)
        XCTAssertEqual(ordered[0], MarkdownListMarker(label: "1.", checkbox: .checked))
    }

    // MARK: - Links in a reply

    /// A reply's links survive its Markdown whatever they point at. In any
    /// session's reply, local or remote — the model's text, which what it
    /// read can steer — only web and mail links open: a `file:` link or an
    /// app's scheme would open, and so launch, something on this Mac.
    func testReplyLinksOpenOnlyOnTheWeb() throws {
        let reply = ChatMessageTextFormatter.inlineSpans("[notes](file:///Applications/Calculator.app)")
        XCTAssertEqual(reply.runs.compactMap(\.link).map(\.scheme), ["file"])

        for link in ["https://example.com/a", "http://example.com", "HTTPS://EXAMPLE.COM", "mailto:me@example.com"] {
            XCTAssertTrue(ReplyLinks.opens(try XCTUnwrap(URL(string: link))), link)
        }
        for link in [
            "file:///Applications/Calculator.app", "file:///tmp/run.command", "file:///Users/me/x.terminal",
            "vscode://file/etc/hosts", "x-apple.systempreferences:", "ssh://host", "smb://host/share",
            "javascript:alert(1)", "data:text/html,hi", "/relative", "relative/path",
        ] {
            XCTAssertFalse(ReplyLinks.opens(try XCTUnwrap(URL(string: link))), link)
        }
    }

    /// Wherever a reply is shown (a card, the completion card, Settings'
    /// preview), its links go through that policy: the reply view applies it
    /// itself rather than leaving it to whoever places it.
    @MainActor
    func testAReplyAppliesTheLinkPolicyItself() {
        let reply = AssistantReplyText(text: "[run](file:///tmp/run.command)", fontSize: 12, lineLimit: nil)
        XCTAssertTrue(String(describing: type(of: reply.body)).contains("ReplyLinks"), "\(type(of: reply.body))")
    }

    // MARK: - Code blocks

    func testShortCodeScrollsOnlyHorizontally() {
        let layout = MarkdownCodeLayout(code: "a\nb")
        XCTAssertFalse(layout.scrollsVertically)
        XCTAssertEqual(layout.text, "a\nb")
        XCTAssertEqual(layout.hiddenLines, 0)
    }

    func testLongCodeScrollsInsideACappedHeight() {
        let code = (1...(MarkdownCodeLayout.visibleLines + 1)).map(String.init).joined(separator: "\n")
        XCTAssertTrue(MarkdownCodeLayout(code: code).scrollsVertically)
        XCTAssertFalse(MarkdownCodeLayout(code: code, capsHeight: false).scrollsVertically,
                       "inside the completion card's scroll area code shows its full height")
    }

    // MARK: - Completion card

    func testCompletionCardRendersOnlyTheNewestAssistantReplyInFull() {
        let prompt = ChatMessage(isUser: true, text: "fix it")
        let older = ChatMessage(isUser: false, text: "old reply")
        let reply = ChatMessage(isUser: false, text: "done")

        XCTAssertEqual(CompletionReplyMetrics.fullReplyId(in: [older, prompt, reply], isCompletionCard: true), reply.id)
        XCTAssertNil(CompletionReplyMetrics.fullReplyId(in: [older, prompt, reply], isCompletionCard: false),
                     "session-list rows keep following the line cap")
        XCTAssertNil(CompletionReplyMetrics.fullReplyId(in: [older, prompt], isCompletionCard: true),
                     "a reply older than the newest prompt is stale")
        XCTAssertNil(CompletionReplyMetrics.fullReplyId(in: [], isCompletionCard: true))
    }

    private func replyMaxHeight(
        window: CGFloat = 510,
        chrome: CGFloat?,
        replies: Int = 1,
        maxVisibleSessions: Int = SettingsDefaults.maxVisibleSessions,
        maxPanelHeight: Int = SettingsDefaults.maxPanelHeight,
        minimum: CGFloat = 40
    ) -> CGFloat {
        CompletionReplyMetrics.maxHeight(
            windowHeight: window,
            chrome: chrome.map { CompletionCardChrome(height: $0, replies: replies) },
            maxVisibleSessions: maxVisibleSessions,
            maxPanelHeight: maxPanelHeight,
            minimumHeight: minimum
        )
    }

    func testCompletionReplyGetsWhatTheRestOfTheCardLeavesInTheWindow() {
        let margin = CompletionReplyMetrics.bottomMargin
        // Card chrome measured at 230pt (notch 38, font 16, task progress,
        // "2 sessions" link…): the reply may use the other 280 − margin.
        XCTAssertEqual(replyMaxHeight(chrome: 230), 510 - 230 - margin)
        // More chrome (an expanded task list, a recap) → less reply.
        XCTAssertEqual(replyMaxHeight(chrome: 330), 510 - 330 - margin)
        // The window is already clamped to the screen; a shorter one shrinks the reply.
        XCTAssertEqual(replyMaxHeight(window: 400, chrome: 230), 400 - 230 - margin)
    }

    func testRepliesOnScreenTogetherShareTheRoom() {
        // Each taking all of it, two replies counted each other as chrome
        // and flipped between two heights for good (#357).
        let room = 510 - 230 - CompletionReplyMetrics.bottomMargin
        XCTAssertEqual(replyMaxHeight(chrome: 230, replies: 2), (room / 2).rounded(.down))
        XCTAssertEqual(replyMaxHeight(chrome: 230, replies: 3), (room / 3).rounded(.down))
    }

    func testCompletionReplyStaysReadableWhenTheCardIsCrowded() {
        XCTAssertEqual(replyMaxHeight(window: 300, chrome: 290, minimum: 45), 45)
        XCTAssertEqual(
            CompletionReplyMetrics.minimumHeight(lineHeight: 14),
            42,
            "three lines of the reply's font"
        )
    }

    @MainActor
    func testCompletionReplyFallsBackToAnEstimateUntilTheCardIsMeasured() {
        let estimate = 510 - CompletionReplyMetrics.estimatedChromeHeight - CompletionReplyMetrics.bottomMargin
        // Nothing measured yet — the window PanelWindowController asks for.
        XCTAssertEqual(replyMaxHeight(window: 0, chrome: nil), estimate)
        // The collapsed bar or the session list says nothing about a reply's room.
        let space = CompletionCardSpace()
        space.recordChrome(CompletionCardChrome(height: 32, replies: 0))
        XCTAssertNil(space.chrome)
        space.recordChrome(CompletionCardChrome(height: 230, replies: 1))
        space.recordChrome(CompletionCardChrome(height: 32, replies: 0))
        XCTAssertEqual(space.chrome, CompletionCardChrome(height: 230, replies: 1))
    }

    func testMaxPanelHeightStillCapsATallWindow() {
        // "Unlimited" sessions: the window may be the whole screen; the
        // maxPanelHeight ceiling keeps an auto-opening card from covering it.
        XCTAssertEqual(
            replyMaxHeight(window: 1100, chrome: 200, maxVisibleSessions: 99, maxPanelHeight: 560),
            560 - 200 - CompletionReplyMetrics.bottomMargin
        )
        // An unset (0) ceiling leaves the window alone.
        XCTAssertEqual(
            replyMaxHeight(window: 1100, chrome: 200, maxPanelHeight: 0),
            1100 - 200 - CompletionReplyMetrics.bottomMargin
        )
    }

    func testCardStopsRefittingWhenItRefitsTooOftenAndRecoversLater() {
        var limiter = CompletionCardRefitLimiter()
        let start: TimeInterval = 100
        for i in 0..<CompletionCardRefitLimiter.maxRefits {
            XCTAssertTrue(limiter.allows(at: start + Double(i) * 0.01))
        }
        XCTAssertFalse(limiter.allows(at: start + 0.5), "a loop's next re-fit is refused")
        XCTAssertTrue(limiter.justTripped, "the first refusal is the one that gets logged")
        XCTAssertFalse(limiter.allows(at: start + 0.6))
        XCTAssertFalse(limiter.justTripped)
        XCTAssertTrue(limiter.allows(at: start + 1.5), "a later change re-fits again")
    }

    @MainActor
    func testATrippedCardKeepsItsChromeForTheRestOfTheWindow() {
        let space = CompletionCardSpace()
        for i in 0..<CompletionCardRefitLimiter.maxRefits {
            space.recordChrome(CompletionCardChrome(height: CGFloat(200 + i), replies: 1), at: Double(i) * 0.01)
        }
        let held = space.chrome
        let next = CompletionCardChrome(height: 400, replies: 2)
        space.recordChrome(next, at: 0.5)
        XCTAssertEqual(space.chrome, held, "past the limit every reply's cap stays where it is")
        space.recordChrome(next, at: 1.5)
        XCTAssertEqual(space.chrome, next, "a later window measures again")
    }

    func testOlderRepliesOnTheCompletionCardTakeOneOrTwoLines() {
        XCTAssertEqual(CompletionReplyMetrics.olderReplyLineLimit(1), 1)
        XCTAssertEqual(CompletionReplyMetrics.olderReplyLineLimit(2), 2)
        XCTAssertEqual(CompletionReplyMetrics.olderReplyLineLimit(5), 2)
        XCTAssertEqual(CompletionReplyMetrics.olderReplyLineLimit(nil), 2, "unlimited setting")
    }

    func testExpandedTaskListScrollsPastSixRows() {
        let visible = AgentTaskProgressView.visibleListedItems
        XCTAssertNil(AgentTaskProgressView.listViewportHeight(itemCount: visible, lineHeight: 13))
        let height = try? XCTUnwrap(AgentTaskProgressView.listViewportHeight(itemCount: 40, lineHeight: 13))
        XCTAssertEqual(height, ((CGFloat(visible) + 0.5) * 16).rounded(), "six and a half rows, whatever the list length")
        XCTAssertEqual(
            AgentTaskProgressView.listViewportHeight(itemCount: 500, lineHeight: 13), height,
            "a runaway list is capped too"
        )
    }

    func testPanelHeightMatchesTheSessionListBudget() {
        XCTAssertEqual(PanelHeightMetrics.desiredHeight(maxVisibleSessions: 5), 510)
        XCTAssertEqual(PanelHeightMetrics.desiredHeight(maxVisibleSessions: 3), 330)
        XCTAssertEqual(PanelHeightMetrics.desiredHeight(maxVisibleSessions: 0), 300, "never below the 300pt floor")
    }

    func testHugeCodeIsCutToBoundLayoutCost() {
        let total = MarkdownCodeLayout.renderedLines + 25
        let layout = MarkdownCodeLayout(code: (1...total).map(String.init).joined(separator: "\n"))
        XCTAssertEqual(layout.hiddenLines, 25)
        XCTAssertEqual(layout.text.split(separator: "\n").count, MarkdownCodeLayout.renderedLines)
    }

    // MARK: - Tables

    func testTableModelFlattensCellsRowMajorWithRules() {
        let table = MarkdownTable(
            header: ["File", "Lines"],
            alignments: [.leading, .trailing],
            rows: [["a.swift", "1"], ["b.swift", "2"]]
        )
        let model = MarkdownTableModel(table: table, tooltipThreshold: 20)
        XCTAssertEqual(model.columnCount, 2)
        XCTAssertEqual(model.cells.map { String($0.text.characters) }, ["File", "Lines", "a.swift", "1", "b.swift", "2"])
        XCTAssertEqual(model.cells.map(\.id), Array(0..<6))
        XCTAssertEqual(model.cells.map(\.isHeader), [true, true, false, false, false, false])
        XCTAssertEqual(model.cells.map(\.drawsTrailingRule), [true, false, true, false, true, false])
        XCTAssertEqual(model.cells.map(\.drawsBottomRule), [true, true, true, true, false, false])
        XCTAssertEqual(model.cells.map(\.isStriped), [false, false, false, false, true, true])
        XCTAssertEqual(model.cells[1].alignment, .trailing)
        XCTAssertEqual(model.cells[0].alignment, .leading)
    }

    func testOnlyLongCellsGetATooltip() {
        let table = MarkdownTable(header: ["short", "a **very** long cell that will be cut"], alignments: [.automatic, .automatic], rows: [])
        let model = MarkdownTableModel(table: table, tooltipThreshold: 20)
        XCTAssertNil(model.cells[0].tooltip)
        XCTAssertEqual(model.cells[1].tooltip, "a very long cell that will be cut")
    }

    func testHugeTablesAreCut() {
        let rows = Array(repeating: ["x"], count: MarkdownTableModel.renderedRows + 7)
        let model = MarkdownTableModel(table: MarkdownTable(header: ["h"], alignments: [.automatic], rows: rows), tooltipThreshold: 20)
        XCTAssertEqual(model.bodyRowCount, MarkdownTableModel.renderedRows)
        XCTAssertEqual(model.hiddenRows, 7)
        XCTAssertEqual(model.cells.count, MarkdownTableModel.renderedRows + 1)
    }

    // MARK: - Inline styling

    func testCodeSpansAreColouredAndOnlyWrappingTextGetsABackground() {
        let wrapping = IslandMarkdownInline.text("run `make` now")
        let truncating = IslandMarkdownInline.truncatingText("run `make` now")
        for (text, expectsBackground) in [(wrapping, true), (truncating, false)] {
            let code = text.runs.first { String(text[$0.range].characters) == "make" }
            XCTAssertEqual(code?.swiftUI.foregroundColor, IslandMarkdownStyle.inlineCode)
            XCTAssertEqual(code?.swiftUI.backgroundColor != nil, expectsBackground)
            let prose = text.runs.first { String(text[$0.range].characters) == "run " }
            XCTAssertNil(prose?.swiftUI.foregroundColor, "prose keeps the row's foreground style")
        }
    }

    func testPreviewsNeverCarryABackground() {
        // SwiftUI paints backgrounds of truncated runs onto the ellipsis.
        let preview = IslandMarkdownInline.preview("```sh\nnpm test\n```", singleLine: true)
        XCTAssertEqual(String(preview.characters), "npm test")
        XCTAssertTrue(preview.runs.allSatisfy { $0.swiftUI.backgroundColor == nil })
        XCTAssertTrue(preview.runs.contains { $0.swiftUI.foregroundColor == IslandMarkdownStyle.inlineCode })
    }

    func testCappedPreviewsKeepLiteralAsterisksUnderscoresAndTildes() {
        let reply = "## Result\n2*3*4 = 24 — see __init__.py and ~/code/a~b~c"
        for singleLine in [true, false] {
            let preview = String(IslandMarkdownInline.preview(reply, singleLine: singleLine).characters)
            XCTAssertTrue(preview.hasSuffix("2*3*4 = 24 — see __init__.py and ~/code/a~b~c"), preview)
        }
    }

    // MARK: - Compact bar

    func testCodexLiveOutputSummaryFlattensMarkdown() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .processing
        session.liveCodexOutput = "## Plan\n- **read** the files\n- run `swift test`\n\n| a | b |\n|---|---|\n| 1 | 2 |"

        XCTAssertEqual(
            SessionLiveOutputDisplay.summary(for: session),
            "Plan · read the files · run swift test · a, b · 1, 2"
        )
    }
}
