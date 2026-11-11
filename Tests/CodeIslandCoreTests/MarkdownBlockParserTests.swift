import XCTest
@testable import CodeIslandCore

final class MarkdownBlockParserTests: XCTestCase {
    private func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownBlockParser.parse(text)
    }

    private func list(_ block: MarkdownBlock?, file: StaticString = #filePath, line: UInt = #line) -> MarkdownList? {
        guard case .list(let list)? = block else {
            XCTFail("expected a list, got \(String(describing: block))", file: file, line: line)
            return nil
        }
        return list
    }

    private func table(_ block: MarkdownBlock?, file: StaticString = #filePath, line: UInt = #line) -> MarkdownTable? {
        guard case .table(let table)? = block else {
            XCTFail("expected a table, got \(String(describing: block))", file: file, line: line)
            return nil
        }
        return table
    }

    private func code(_ block: MarkdownBlock?, file: StaticString = #filePath, line: UInt = #line) -> MarkdownCodeBlock? {
        guard case .code(let code)? = block else {
            XCTFail("expected a code block, got \(String(describing: block))", file: file, line: line)
            return nil
        }
        return code
    }

    // MARK: - Headings & paragraphs

    func testEmptyAndBlankInputProduceNoBlocks() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("  \n\n\t\n"), [])
    }

    func testATXHeadingsStripMarkersAndClosingSequence() {
        XCTAssertEqual(parse("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(parse("### Sub section ##"), [.heading(level: 3, text: "Sub section")])
        XCTAssertEqual(parse("## C#"), [.heading(level: 2, text: "C#")])
        XCTAssertEqual(parse("#"), [.heading(level: 1, text: "")], "a streamed lone # is an empty heading, not a crash")
    }

    func testClosingSequenceNeedsABlankBeforeIt() {
        XCTAssertEqual(parse("# Title\t###"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(parse("# a # b ##"), [.heading(level: 1, text: "a # b")])
        XCTAssertEqual(parse("# issue \\#"), [.heading(level: 1, text: "issue \\#")], "an escaped # is text")
        XCTAssertEqual(parse("## ## #"), [.heading(level: 2, text: "##")])
        XCTAssertEqual(parse("## ###"), [.heading(level: 2, text: "")])
    }

    func testHeadingWithALongRunOfBlanksParsesInLinearTime() {
        // The closing-sequence regex retried from every blank: 5 000 spaces
        // took ~0.5s and 20 000 about 10s, on the main thread.
        let heading = "# a" + String(repeating: " ", count: 20_000) + "b"
        let start = Date()
        let blocks = parse(heading)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(blocks, [.heading(level: 1, text: "a" + String(repeating: " ", count: 20_000) + "b")])
        XCTAssertLessThan(elapsedMs, 50)

        let tabs = "## x" + String(repeating: "\t", count: 20_000) + "y"
        let tabStart = Date()
        _ = parse(tabs)
        XCTAssertLessThan(Date().timeIntervalSince(tabStart) * 1000, 50)
    }

    func testHashWithoutSpaceOrTooManyHashesIsText() {
        XCTAssertEqual(parse("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(parse("####### seven"), [.paragraph("####### seven")])
    }

    func testSetextHeadings() {
        XCTAssertEqual(parse("Title\n==="), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(parse("Sub\n---"), [.heading(level: 2, text: "Sub")])
    }

    func testStreamedBulletStartDoesNotTurnPreviousLineIntoHeading() {
        // "Files:\n-" is what a reply looks like one chunk before "- a.swift".
        XCTAssertEqual(parse("Files:\n-"), [.paragraph("Files:\n-")])
    }

    func testParagraphsKeepLineBreaksAndSplitOnBlankLines() {
        XCTAssertEqual(
            parse("first line\n  second line  \n\nnext paragraph"),
            [.paragraph("first line\nsecond line"), .paragraph("next paragraph")]
        )
    }

    func testThematicBreaks() {
        for rule in ["---", "***", "___", "- - -", " * * * "] {
            XCTAssertEqual(parse("a\n\n\(rule)\n\nb"), [.paragraph("a"), .thematicBreak, .paragraph("b")], rule)
        }
    }

    // MARK: - Lists

    func testBulletListWithMixedMarkers() {
        guard let list = list(parse("- one\n* two\n+ three").first) else { return }
        XCTAssertFalse(list.isOrdered)
        XCTAssertEqual(list.items.map(\.blocks), [[.paragraph("one")], [.paragraph("two")], [.paragraph("three")]])
    }

    func testOrderedListKeepsItsStartNumber() {
        guard let list = list(parse("3. three\n4) four").first) else { return }
        XCTAssertTrue(list.isOrdered)
        XCTAssertEqual(list.start, 3)
        XCTAssertEqual(list.items.count, 2)
    }

    func testOnlyAListStartingAtOneInterruptsAParagraph() {
        XCTAssertEqual(parse("It was released in\n2024. It sold well."),
                       [.paragraph("It was released in\n2024. It sold well.")])

        let blocks = parse("Steps:\n1. build\n2. test")
        XCTAssertEqual(blocks.first, .paragraph("Steps:"))
        XCTAssertEqual(list(blocks.last)?.items.count, 2)
    }

    func testMarkerLookalikesStayText() {
        XCTAssertEqual(parse("**bold** start"), [.paragraph("**bold** start")])
        XCTAssertEqual(parse("-1 degrees"), [.paragraph("-1 degrees")])
        XCTAssertEqual(parse("1.5x faster"), [.paragraph("1.5x faster")])
    }

    func testNestedBulletLists() {
        let blocks = parse("- a\n  - b\n    - c\n- d")
        guard let outer = list(blocks.first) else { return }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(outer.items.count, 2)
        XCTAssertEqual(outer.items[0].blocks.first, .paragraph("a"))
        guard let middle = list(outer.items[0].blocks.last) else { return }
        XCTAssertEqual(middle.items[0].blocks.first, .paragraph("b"))
        guard let inner = list(middle.items[0].blocks.last) else { return }
        XCTAssertEqual(inner.items.map(\.blocks), [[.paragraph("c")]])
        XCTAssertEqual(outer.items[1].blocks, [.paragraph("d")])
    }

    func testTwoSpaceNestingUnderOrderedItem() {
        // CommonMark wants three spaces under "1. "; models routinely use two.
        guard let outer = list(parse("1. first\n  - detail\n2. second").first) else { return }
        XCTAssertEqual(outer.items.count, 2)
        XCTAssertNotNil(list(outer.items[0].blocks.last))
    }

    func testOneSpaceIndentIsASiblingNotAChild() {
        guard let outer = list(parse("- a\n - b").first) else { return }
        XCTAssertEqual(outer.items.count, 2)
    }

    func testTaskListItems() {
        guard let list = list(parse("- [ ] todo\n- [x] done\n- [X] also done\n- [link](https://x.dev)\n- [x]").first) else { return }
        XCTAssertEqual(list.items.map(\.checkbox), [.unchecked, .checked, .checked, nil, .checked])
        XCTAssertEqual(list.items[0].blocks, [.paragraph("todo")])
        XCTAssertEqual(list.items[3].blocks, [.paragraph("[link](https://x.dev)")])
        XCTAssertEqual(list.items[4].blocks, [], "a streamed bare checkbox has no text yet")
    }

    func testBlankLinesBetweenItemsKeepOneList() {
        guard let list = list(parse("- a\n\n- b\n\n\n- c").first) else { return }
        XCTAssertEqual(list.items.count, 3)
    }

    func testSwitchingBetweenBulletAndOrderedStartsANewList() {
        let blocks = parse("- a\n1. b")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(list(blocks[0])?.isOrdered, false)
        XCTAssertEqual(list(blocks[1])?.isOrdered, true)
    }

    func testLazyContinuationStaysInItem() {
        guard let list = list(parse("- first\ncontinued\n- second").first) else { return }
        XCTAssertEqual(list.items[0].blocks, [.paragraph("first\ncontinued")])
        XCTAssertEqual(list.items.count, 2)
    }

    func testParagraphAfterBlankLineEndsList() {
        let blocks = parse("- a\n\nafter")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last, .paragraph("after"))
    }

    func testListItemWithIndentedFencedCode() {
        let blocks = parse("1. Run:\n   ```sh\n   npm i\n\n   npm test\n   ```\n2. Next")
        guard let list = list(blocks.first) else { return }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].blocks.first, .paragraph("Run:"))
        XCTAssertEqual(code(list.items[0].blocks.last), MarkdownCodeBlock(language: "sh", code: "npm i\n\nnpm test", isClosed: true))
    }

    func testUnderIndentedCodeInsideListItemDoesNotRunAway() {
        // The body and closing fence sit at column 0; without fence tracking
        // the closer would re-open as a fence that swallows "2. Next".
        let blocks = parse("1. Run:\n   ```sh\nnpm i\n```\n2. Next")
        guard let list = list(blocks.first) else { return }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(code(list.items[0].blocks.last)?.code, "npm i")
        XCTAssertEqual(list.items[1].blocks, [.paragraph("Next")])
    }

    func testUnindentedFenceAfterItemEndsTheList() {
        let blocks = parse("1. Run:\n```sh\nnpm i\n```")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(list(blocks.first)?.items.count, 1)
        XCTAssertEqual(code(blocks.last)?.code, "npm i")
    }

    // MARK: - Fenced code

    func testFencedCodeKeepsLanguageAndIndentation() {
        let block = code(parse("```swift title=\"x.swift\"\nfunc a() {\n    b()\n}\n```").first)
        XCTAssertEqual(block, MarkdownCodeBlock(language: "swift", code: "func a() {\n    b()\n}", isClosed: true))
    }

    func testFencedCodeInterruptsParagraphAndLeavesInlineSyntaxAlone() {
        let blocks = parse("Run the following:\n```\nvar x = *y* + `z`\n```\nand you're done.")
        XCTAssertEqual(blocks, [
            .paragraph("Run the following:"),
            .code(MarkdownCodeBlock(language: nil, code: "var x = *y* + `z`", isClosed: true)),
            .paragraph("and you're done."),
        ])
    }

    func testTildeAndLongerFencesNestShorterFences() {
        XCTAssertEqual(code(parse("~~~\na ``` b\n~~~").first)?.code, "a ``` b")
        let nested = code(parse("````md\n```js\nx\n```\n````").first)
        XCTAssertEqual(nested, MarkdownCodeBlock(language: "md", code: "```js\nx\n```", isClosed: true))
    }

    func testFenceClosesOnlyOnABareFenceLine() {
        XCTAssertEqual(code(parse("```\na\n``` not a close\n```").first)?.code, "a\n``` not a close")
    }

    func testIndentedFenceStripsItsIndentFromTheBody() {
        XCTAssertEqual(code(parse("  ```\n  one\n    two\n  ```").first)?.code, "one\n  two")
    }

    func testTripleBacktickSpanOnOneLineIsNotAFence() {
        XCTAssertEqual(parse("```let x = 1```"), [.paragraph("```let x = 1```")])
    }

    func testStreamingUnclosedFenceKeepsItsContent() {
        let blocks = parse("Here:\n```py\nprint(1)\nprint(2)\n\n")
        XCTAssertEqual(blocks.first, .paragraph("Here:"))
        XCTAssertEqual(code(blocks.last), MarkdownCodeBlock(language: "py", code: "print(1)\nprint(2)", isClosed: false))
    }

    func testStreamingFenceOpenerAlone() {
        XCTAssertEqual(parse("```"), [.code(MarkdownCodeBlock(language: nil, code: "", isClosed: false))])
        XCTAssertEqual(parse("text\n``"), [.paragraph("text\n``")], "two backticks aren't a fence yet")
    }

    // MARK: - Tables

    func testTableWithAlignments() {
        guard let table = table(parse("| L | C | R | N |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |").first) else { return }
        XCTAssertEqual(table.header, ["L", "C", "R", "N"])
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing, .automatic])
        XCTAssertEqual(table.rows, [["1", "2", "3", "4"]])
    }

    func testTableWithoutOuterPipes() {
        guard let table = table(parse("name | size\n--- | ---:\na.swift | 10").first) else { return }
        XCTAssertEqual(table.header, ["name", "size"])
        XCTAssertEqual(table.alignments, [.automatic, .trailing])
        XCTAssertEqual(table.rows, [["a.swift", "10"]])
    }

    func testTableCellsKeepEscapedPipesAndPipesInsideCodeSpans() {
        guard let table = table(parse("| a | b |\n|---|---|\n| `x | y` | c \\| d |").first) else { return }
        XCTAssertEqual(table.rows, [["`x | y`", "c | d"]])
    }

    func testTableWidensInsteadOfDroppingExtraCells() {
        guard let table = table(parse("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |").first) else { return }
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.header, ["a", "b", ""])
        XCTAssertEqual(table.alignments.count, 3)
        XCTAssertEqual(table.rows, [["1", "", ""], ["1", "2", "3"]])
    }

    func testStrayLineOfPipesCannotWidenATableWithoutBound() {
        // A line of 300 pipes under a table used to make it 299 columns wide.
        let body = (1...200).map { "| \($0) | row |" }.joined(separator: "\n")
        let text = "| a | b |\n|---|---|\n" + body + "\n" + String(repeating: "|", count: 300)
        let start = Date()
        guard let table = table(parse(text).first) else { return }
        XCTAssertLessThan(Date().timeIntervalSince(start) * 1000, 200)
        XCTAssertEqual(table.columnCount, MarkdownBlockParser.maxTableColumns)
        XCTAssertEqual(table.alignments.count, MarkdownBlockParser.maxTableColumns)
        XCTAssertTrue(table.rows.allSatisfy { $0.count == MarkdownBlockParser.maxTableColumns })
        XCTAssertEqual(table.rows.count, 201)
        XCTAssertEqual(table.rows.last, Array(repeating: "", count: MarkdownBlockParser.maxTableColumns))
    }

    func testCellsPastTheColumnCapJoinTheLastColumn() {
        let cells = (1...20).map { "c\($0)" }
        let text = "| h |\n|---|\n| " + cells.joined(separator: " | ") + " |"
        guard let table = table(parse(text).first) else { return }
        let row = table.rows[0]
        XCTAssertEqual(row.count, MarkdownBlockParser.maxTableColumns)
        XCTAssertEqual(Array(row.prefix(15)), Array(cells.prefix(15)))
        XCTAssertEqual(row.last, "c16 | c17 | c18 | c19 | c20", "no cell is dropped")
    }

    func testTableEndsAtBlankOrPipelessLine() {
        let blocks = parse("| a |\n|---|\n| 1 |\nafter\n\n| b |\n|---|\n| 2 |\n\nnext")
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(table(blocks[0])?.rows, [["1"]])
        XCTAssertEqual(blocks[1], .paragraph("after"))
        XCTAssertEqual(table(blocks[2])?.rows, [["2"]])
        XCTAssertEqual(blocks[3], .paragraph("next"))
    }

    func testTableInterruptsAParagraph() {
        let blocks = parse("Results:\n| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks.first, .paragraph("Results:"))
        XCTAssertEqual(table(blocks.last)?.header, ["a", "b"])
    }

    func testDashesUnderPipelessTextAreAHeadingNotATable() {
        XCTAssertEqual(parse("a | b\n---"), [.heading(level: 2, text: "a | b")])
    }

    func testStreamingTableWithHalfWrittenDelimiterRow() {
        for partial in ["|", "|--", "| --- | :-"] {
            guard let table = table(parse("| a | b |\n\(partial)").first) else { continue }
            XCTAssertEqual(table.header, ["a", "b"], partial)
            XCTAssertEqual(table.rows, [], partial)
        }
    }

    func testMalformedDelimiterFollowedByMoreTextIsNotATable() {
        XCTAssertEqual(parse("| a | b |\n|--x\nmore"), [.paragraph("| a | b |\n|--x\nmore")])
        XCTAssertEqual(parse("| a | b |\n|\nmore"), [.paragraph("| a | b |\n|\nmore")])
    }

    func testLoneHeaderRowStaysAParagraph() {
        XCTAssertEqual(parse("| a | b |"), [.paragraph("| a | b |")])
    }

    func testStreamingRowCutMidCell() {
        XCTAssertEqual(table(parse("| a | b |\n|---|---|\n| 1 | tw").first)?.rows, [["1", "tw"]])
    }

    // MARK: - Quotes

    func testBlockQuoteWithLazyContinuation() {
        XCTAssertEqual(
            parse("> **Note**\n> second\nlazy\n\nafter"),
            [.quote([.paragraph("**Note**\nsecond\nlazy")]), .paragraph("after")]
        )
    }

    func testBlockQuoteContainsBlocks() {
        let blocks = parse("> # Title\n> - a\n> - b\n>\n> ```\n> code\n> ```")
        guard case .quote(let inner)? = blocks.first else { return XCTFail("expected quote") }
        XCTAssertEqual(inner.first, .heading(level: 1, text: "Title"))
        XCTAssertEqual(list(inner.dropFirst().first)?.items.count, 2)
        XCTAssertEqual(code(inner.last)?.code, "code")
    }

    func testNestedQuotes() {
        XCTAssertEqual(parse("> outer\n>> inner"), [.quote([.paragraph("outer"), .quote([.paragraph("inner")])])])
    }

    // MARK: - Robustness

    func testCRLFAndTabIndentation() {
        guard let outer = list(parse("- a\r\n\t- b\r\n- c").first) else { return }
        XCTAssertEqual(outer.items.count, 2)
        XCTAssertNotNil(list(outer.items[0].blocks.last))
    }

    func testDeepNestingIsCappedWithoutLosingText() {
        let deepList = (0..<40).map { String(repeating: "  ", count: $0) + "- level\($0)" }.joined(separator: "\n")
        let deepQuote = String(repeating: ">", count: 40) + " bottom"
        for text in [deepList, deepQuote] {
            let blocks = parse(text)
            XCTAssertLessThanOrEqual(maxDepth(blocks), MarkdownBlockParser.maxNestingDepth + 1)
            XCTAssertTrue(words(in: text).isSubset(of: words(in: blocks)))
        }
    }

    /// Every streamed prefix of a reply that uses every construct must parse
    /// without dropping a word — the island re-renders on each chunk.
    func testEveryStreamingPrefixKeepsAllWords() {
        let reply = """
        ## Summary
        Fixed the **login** bug in `auth.ts` — see [docs](https://example.dev/auth).

        1. Reproduced locally
           - token refresh skipped expiry
        2. Patched:
           ```swift
           guard token.isValid else { return }
           ```
        - [x] unit tests
        - [ ] manual check

        | File | Lines | Status |
        |:-----|------:|:------:|
        | auth.ts | 12 | done |
        | session.ts | 4 | `a | b` |

        > **Note** restart the server
        continued note

        ---
        Setext Title
        ===
        ~~~
        trailing unclosed fence
        """
        for end in reply.indices {
            let prefix = String(reply[..<end])
            XCTAssertTrue(words(in: prefix).isSubset(of: words(in: parse(prefix))),
                          "lost words at prefix length \(prefix.count)")
        }
    }

    func testRandomisedInputNeverLosesWords() {
        let fragments = [
            "# head", "## sub ##", "para text", "- item", "  - child", "1. first", "3) third", "- [ ] task",
            "- [x] done", "```js", "```", "~~~", "| c1 | c2 |", "|---|:-:|", "| v1 | v2 |", "> quote",
            ">> deeper", "---", "***", "", "   ", "\tindented", "===", "trailing words", "`code | span`",
        ]
        var generator = SeededGenerator(seed: 0xC0DE)
        for _ in 0..<400 {
            let count = Int.random(in: 1...18, using: &generator)
            let text = (0..<count)
                .map { _ in fragments.randomElement(using: &generator)! }
                .joined(separator: "\n")
            XCTAssertTrue(words(in: text).isSubset(of: words(in: parse(text))), "lost words in:\n\(text)")
        }
    }

    func testCachedBlocksMatchTheParser() {
        let text = "- a\n- b\n\n```\nx\n```"
        XCTAssertEqual(ChatMessageTextFormatter.markdownBlocks(text), parse(text))
        XCTAssertEqual(ChatMessageTextFormatter.markdownBlocks(text), parse(text))
    }

    func testParsingALargeReplyStaysFast() {
        let chunk = """
        ### Step
        Some **explanation** with `code` and a [link](https://example.dev).
        - item one
          - nested item
        - [x] task
        | a | b |
        |---|--:|
        | 1 | 2 |
        ```swift
        let value = compute()
        ```

        """
        let reply = String(repeating: chunk, count: 400)  // ~70 KB
        let start = Date()
        let blocks = MarkdownBlockParser.parse(reply)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        print("[bench] MarkdownBlockParser.parse \(reply.utf8.count) bytes: \(String(format: "%.2f", elapsedMs))ms")
        XCTAssertEqual(blocks.filter { if case .table = $0 { return true } else { return false } }.count, 400)
        XCTAssertLessThan(elapsedMs, 3_000)
    }

    // MARK: - Helpers

    /// Words of two or more letters/digits that aren't pure numbers: list
    /// ordinals and the `x` of a checkbox legitimately move into structure.
    private func words(in text: String) -> Set<String> {
        Set(text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) })
    }

    private func words(in blocks: [MarkdownBlock]) -> Set<String> {
        words(in: allText(blocks))
    }

    private func allText(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text):
                return text
            case .list(let list):
                return list.items.map { allText($0.blocks) }.joined(separator: " ")
            case .code(let code):
                return (code.language ?? "") + " " + code.code
            case .table(let table):
                return (table.header + table.rows.flatMap { $0 }).joined(separator: " ")
            case .quote(let inner):
                return allText(inner)
            case .thematicBreak:
                return ""
            }
        }.joined(separator: " ")
    }

    private func maxDepth(_ blocks: [MarkdownBlock]) -> Int {
        blocks.map { block -> Int in
            switch block {
            case .list(let list): return 1 + (list.items.map { maxDepth($0.blocks) }.max() ?? 0)
            case .quote(let inner): return 1 + maxDepth(inner)
            default: return 0
            }
        }.max() ?? 0
    }
}

/// Deterministic xorshift so the randomised test replays identically.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
