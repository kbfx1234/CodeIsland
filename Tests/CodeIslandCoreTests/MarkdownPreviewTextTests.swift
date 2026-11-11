import XCTest
@testable import CodeIslandCore

final class MarkdownPreviewTextTests: XCTestCase {
    private let reply = """
    ## Summary
    Fixed the **login** bug in `auth.ts`.

    Changes:
    - [x] token refresh checks expiry
    - [ ] manual QA

    | File | Lines |
    |------|------:|
    | auth.ts | 12 |

    ```bash
    npm test
    npm run lint
    ```
    """

    func testSingleLinePreviewCarriesNoMarkdownSyntax() {
        XCTAssertEqual(
            MarkdownPreviewText.plain(reply, singleLine: true),
            "Summary · Fixed the login bug in auth.ts. · Changes: ☑ token refresh checks expiry · ☐ manual QA"
                + " · File, Lines · auth.ts, 12 · npm test …"
        )
    }

    func testMultiLinePreviewKeepsOneLinePerBlock() {
        XCTAssertEqual(
            MarkdownPreviewText.plain(reply, singleLine: false),
            """
            Summary
            Fixed the login bug in auth.ts.
            Changes:
            ☑ token refresh checks expiry · ☐ manual QA
            File, Lines · auth.ts, 12
            npm test …
            """
        )
    }

    func testMultiLinePreviewKeepsParagraphLineBreaks() {
        XCTAssertEqual(MarkdownPreviewText.plain("one\ntwo", singleLine: false), "one\ntwo")
        XCTAssertEqual(MarkdownPreviewText.plain("one\ntwo", singleLine: true), "one two")
    }

    func testOrderedListsKeepTheirNumbersAndNestedItemsFlowInline() {
        XCTAssertEqual(
            MarkdownPreviewText.plain("Steps:\n\n3. build\n   - debug\n4. test", singleLine: true),
            "Steps: 3. build · debug · 4. test"
        )
    }

    func testQuotesAndBreaksLoseTheirMarkers() {
        XCTAssertEqual(
            MarkdownPreviewText.plain("> **Note** restart\n\n---\n\ndone", singleLine: true),
            "Note restart · done"
        )
    }

    func testSingleLineCodeBlockHasNoEllipsis() {
        XCTAssertEqual(MarkdownPreviewText.plain("Run:\n```\n  make  \n```", singleLine: true), "Run: make")
    }

    func testEmptyTableCellsAreSkipped() {
        XCTAssertEqual(
            MarkdownPreviewText.plain("| a | | c |\n|---|---|---|\n| 1 | 2 | |", singleLine: true),
            "a, c · 1, 2"
        )
    }

    func testStreamingFragmentsPreviewCleanly() {
        XCTAssertEqual(MarkdownPreviewText.plain("| a | b |\n|--", singleLine: true), "a, b")
        XCTAssertEqual(MarkdownPreviewText.plain("Here:\n```py", singleLine: true), "Here:")
        XCTAssertEqual(MarkdownPreviewText.plain("##", singleLine: true), "")
        XCTAssertEqual(MarkdownPreviewText.plain("- ", singleLine: true), "")
        XCTAssertEqual(MarkdownPreviewText.plain("", singleLine: false), "")
    }

    func testHeadingsStayBoldAndCodeKeepsItsCodeIntent() {
        let preview = MarkdownPreviewText.attributed(
            MarkdownBlockParser.parse("# Title\nuse `make`\n```\nnpm test\n```"),
            singleLine: true
        )
        let runs = preview.runs.map { (String(preview[$0.range].characters), $0.inlinePresentationIntent) }
        XCTAssertTrue(runs.contains { $0.0 == "Title" && $0.1?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(runs.contains { $0.0 == "make" && $0.1?.contains(.code) == true })
        XCTAssertTrue(runs.contains { $0.0 == "npm test" && $0.1?.contains(.code) == true })
        XCTAssertFalse(runs.contains { $0.0.contains(" · ") && $0.1 != nil }, "separators carry no styling")
    }

    func testInlineLinksSurviveAsLinks() {
        let preview = ChatMessageTextFormatter.markdownPreview("- see [docs](https://example.dev)", singleLine: true)
        XCTAssertEqual(String(preview.characters), "see docs")
        XCTAssertTrue(preview.runs.contains { $0.link == URL(string: "https://example.dev") })
    }

    // MARK: - Source budget

    private func hugeReply(bytes: Int) -> String {
        var parts: [String] = []
        var size = 0
        var index = 0
        while size < bytes {
            index += 1
            let part: String
            switch index % 4 {
            case 0: part = "## Section \(index)\nSome **bold** text with `code` and a [link](https://example.dev/\(index))."
            case 1: part = "- item \(index)\n- item with *emphasis*\n- [x] done"
            case 2: part = "```swift\nlet x\(index) = 1\nprint(x\(index))\n```"
            default: part = "| a | b |\n|---|---|\n| \(index) | **\(index)** |"
            }
            parts.append(part)
            size += part.utf8.count + 2
        }
        return parts.joined(separator: "\n\n")
    }

    func testPreviewOfAHugeReplyFlattensOnlyItsHead() {
        // A 139 KB Codex output took ~120ms to flatten, on every chunk,
        // for a live bar that shows 160 characters.
        let reply = hugeReply(bytes: 300_000)
        let start = Date()
        let preview = String(ChatMessageTextFormatter.markdownPreview(reply, singleLine: true).characters)
        let previewTime = Date().timeIntervalSince(start)

        let fullStart = Date()
        let full = MarkdownPreviewText.plain(reply, singleLine: true)
        let fullTime = Date().timeIntervalSince(fullStart)
        // Against flattening the whole reply rather than a fixed budget: a
        // machine busy with other test runs slows both alike.
        XCTAssertLessThan(previewTime, fullTime / 2, "preview \(previewTime * 1000) ms, whole reply \(fullTime * 1000) ms")
        XCTAssertEqual(String(preview.prefix(2_000)), String(full.prefix(2_000)), "the visible head is unchanged")
        XCTAssertLessThan(preview.utf8.count, 16 * 1024)
    }

    func testPreviewSourceKeepsShortRepliesWhole() {
        let reply = hugeReply(bytes: MarkdownPreviewText.sourceBudget - 100)
        XCTAssertEqual(MarkdownPreviewText.previewSource(reply), reply)
    }

    func testLongCodeDoesNotCountAgainstTheBudget() {
        let code = (1...1_500).map { "line \($0) of a long sample" }.joined(separator: "\n")
        let reply = "Here is the fix:\n```swift\n\(code)\n```\nThen run the tests."
        XCTAssertGreaterThan(reply.utf8.count, MarkdownPreviewText.sourceBudget)
        XCTAssertEqual(
            MarkdownPreviewText.plain(MarkdownPreviewText.previewSource(reply), singleLine: true),
            "Here is the fix: line 1 of a long sample … · Then run the tests."
        )
    }

    func testUnclosedFenceAndOneHugeLineStillEnd() {
        let unclosed = "Output:\n```\n" + String(repeating: "x\n", count: 100_000)
        let head = MarkdownPreviewText.previewSource(unclosed)
        XCTAssertLessThanOrEqual(head.utf8.count, MarkdownPreviewText.sourceHardLimit)
        XCTAssertEqual(MarkdownPreviewText.plain(head, singleLine: true), "Output: x …")

        let oneLine = "Result: " + String(repeating: "word ", count: 50_000)
        let cut = MarkdownPreviewText.previewSource(oneLine)
        XCTAssertTrue(oneLine.hasPrefix(cut))
        XCTAssertEqual(cut.utf8.count, MarkdownPreviewText.sourceBudget)
        XCTAssertEqual(MarkdownPreviewText.previewSource(cut), cut, "cutting twice changes nothing")
    }

    func testRenderCachesHoldABoundedAmountOfText() {
        // 24 distinct ~64 KB replies: 1.5 MB of keys against a 1 MB budget
        // (the count limit alone would have kept all of them).
        for index in 0..<24 {
            let reply = "reply \(index)\n" + String(repeating: "Some **text** here.\n", count: 3_200)
            _ = ChatMessageTextFormatter.markdownBlocks(reply)
            _ = ChatMessageTextFormatter.markdownPreview(reply, singleLine: true)
        }
        let limit = TextRenderCache<String, Int>.defaultByteLimit
        for bytes in ChatMessageTextFormatter.cachedTextBytes {
            XCTAssertLessThanOrEqual(bytes, limit)
        }
    }

    func testCacheEvictsByBytesAndStillHoldsAnOversizedEntry() {
        var cache = TextRenderCache<String, Int>(countLimit: 100, byteLimit: 10)
        var renders = 0
        _ = cache.value(for: "aaaa") { renders += 1; return 1 }
        _ = cache.value(for: "bbbb") { renders += 1; return 2 }
        XCTAssertEqual(cache.byteCount, 8)
        _ = cache.value(for: "cccc") { renders += 1; return 3 }
        XCTAssertEqual(cache.count, 1, "over the byte budget: evicted wholesale")
        XCTAssertEqual(cache.byteCount, 4)

        let huge = String(repeating: "z", count: 50)
        _ = cache.value(for: huge) { renders += 1; return 4 }
        XCTAssertEqual(cache.value(for: huge) { renders += 1; return 5 }, 4, "an oversized entry is still cached")
        XCTAssertEqual(renders, 4)
    }

    func testPreviewCacheKeepsSingleAndMultiLineApart() {
        let text = "# A\nb"
        XCTAssertEqual(String(ChatMessageTextFormatter.markdownPreview(text, singleLine: true).characters), "A · b")
        XCTAssertEqual(String(ChatMessageTextFormatter.markdownPreview(text, singleLine: false).characters), "A\nb")
        XCTAssertEqual(String(ChatMessageTextFormatter.markdownPreview(text, singleLine: true).characters), "A · b")
    }
}
