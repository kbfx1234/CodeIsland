import XCTest
@testable import CodeIslandCore

/// `*`, `_` and `~` that belong to a word must survive inline rendering —
/// previews and companion devices used to lose them (`2*3*4` → `234`).
final class MarkdownInlineLiteralsTests: XCTestCase {
    private func rendered(_ text: String) -> AttributedString {
        ChatMessageTextFormatter.inlineSpans(text)
    }

    private func plain(_ text: String) -> String {
        String(rendered(text).characters)
    }

    func testDelimitersInsideWordsStayLiteral() {
        for text in [
            "2*3*4 = 24",
            "2**10 and 3**2",
            "globs src/*.swift and tests/*.swift",
            "edit __init__.py and __main__.py",
            "~/code/app … a~b~c",
            "about ~5~10 minutes",
            "snake_case_name",
            "the __init__ method",
            "if __name__ == \"__main__\":",
            "override __init_subclass__ too",
        ] {
            XCTAssertEqual(plain(text), text)
            XCTAssertTrue(rendered(text).runs.allSatisfy { $0.inlinePresentationIntent == nil }, text)
        }
    }

    func testEmphasisAtWordBoundariesStillRenders() {
        let cases: [(String, String, InlinePresentationIntent)] = [
            ("**Note**: restart", "Note", .stronglyEmphasized),
            ("an *important* step.", "important", .emphasized),
            ("(**bold**)", "bold", .stronglyEmphasized),
            ("这是**重点**内容", "重点", .stronglyEmphasized),
            ("**完成**，下一步", "完成", .stronglyEmphasized),
            ("~~gone~~ now", "gone", .strikethrough),
            ("__bold words__ here", "bold words", .stronglyEmphasized),
        ]
        for (text, word, intent) in cases {
            let attributed = rendered(text)
            XCTAssertFalse(String(attributed.characters).contains("*"), text)
            let run = attributed.runs.first { String(attributed[$0.range].characters) == word }
            XCTAssertEqual(run?.inlinePresentationIntent?.contains(intent), true, text)
        }
    }

    func testCodeSpansEscapesAndLinksAreLeftAlone() {
        XCTAssertEqual(plain("run `a*b*c` now"), "run a*b*c now")
        XCTAssertEqual(plain("literal \\*star\\* here"), "literal *star* here")

        let url = rendered("see https://example.dev/a_b_c/d~e and more")
        XCTAssertEqual(String(url.characters), "see https://example.dev/a_b_c/d~e and more")
        XCTAssertTrue(url.runs.contains { $0.link == URL(string: "https://example.dev/a_b_c/d~e") })

        let link = rendered("[the_docs](https://example.dev/x_y) for 2*3*4")
        XCTAssertEqual(String(link.characters), "the_docs for 2*3*4")
        XCTAssertTrue(link.runs.contains { $0.link == URL(string: "https://example.dev/x_y") })

        XCTAssertEqual(plain("mail first_last@example.dev"), "mail first_last@example.dev")
    }

    func testCodeSpanThatRunsPastAWordIsNotEscapedInside() {
        XCTAssertEqual(plain("`a_b c*d*e` then x*y*z"), "a_b c*d*e then x*y*z")
        XCTAssertEqual(plain("unmatched ` then 2*3*4"), "unmatched ` then 2*3*4")
    }

    func testPreviewsKeepTheCharacters() {
        XCTAssertEqual(MarkdownPreviewText.plain("- 2*3*4 = 24\n- run `x`", singleLine: true), "2*3*4 = 24 · run x")
        XCTAssertEqual(MarkdownPreviewText.plain("## Edit __init__.py\ncd ~/code/a", singleLine: true), "Edit __init__.py · cd ~/code/a")
    }

    func testEscapingIsLinearOnPathologicalInput() {
        let inputs = [
            String(repeating: "a*", count: 50_000),
            String(repeating: "*.", count: 50_000),
            String(repeating: "`a``b", count: 20_000),
            String(repeating: "x_", count: 50_000),
        ]
        for input in inputs {
            let start = Date()
            _ = MarkdownInlineLiterals.escapingWordDelimiters(input)
            XCTAssertLessThan(Date().timeIntervalSince(start) * 1000, 250, String(input.prefix(6)))
        }
    }

    func testTextWithoutDelimitersIsReturnedAsIs() {
        let text = "plain words, no markers"
        XCTAssertEqual(MarkdownInlineLiterals.escapingWordDelimiters(text), text)
    }
}
