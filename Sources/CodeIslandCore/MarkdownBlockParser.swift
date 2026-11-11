import Foundation

// MARK: - Model

/// Block-level structure of an assistant reply.
///
/// Inline spans (bold, code, links, …) stay as raw Markdown source inside each
/// block: the renderer hands them to the inline parser separately, so the
/// block layer never has to re-implement emphasis rules and the inline layer
/// never sees list markers or table pipes.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Lines of one paragraph, joined with "\n". Newlines are kept rather
    /// than folded into spaces — assistant replies use them intentionally and
    /// the island has always shown them.
    case paragraph(String)
    case list(MarkdownList)
    case code(MarkdownCodeBlock)
    case table(MarkdownTable)
    case quote([MarkdownBlock])
    case thematicBreak
}

public struct MarkdownList: Equatable, Sendable {
    public var isOrdered: Bool
    /// Number of the first item; later items count up from it, as in
    /// CommonMark (so "1. 1. 1." still renders as 1, 2, 3).
    public var start: Int
    public var items: [MarkdownListItem]

    public init(isOrdered: Bool, start: Int, items: [MarkdownListItem]) {
        self.isOrdered = isOrdered
        self.start = start
        self.items = items
    }
}

public struct MarkdownListItem: Equatable, Sendable {
    public enum Checkbox: Equatable, Sendable {
        case unchecked
        case checked
    }

    /// Set for GFM task items (`- [ ]` / `- [x]`).
    public var checkbox: Checkbox?
    /// The item's content: usually one paragraph, plus nested lists, code, …
    public var blocks: [MarkdownBlock]

    public init(checkbox: Checkbox? = nil, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

public struct MarkdownCodeBlock: Equatable, Sendable {
    /// First word of the fence's info string (```swift → "swift").
    public var language: String?
    public var code: String
    /// False while a streaming reply has opened the fence but not closed it.
    public var isClosed: Bool

    public init(language: String?, code: String, isClosed: Bool) {
        self.language = language
        self.code = code
        self.isClosed = isClosed
    }
}

public enum MarkdownTableAlignment: Equatable, Sendable {
    case automatic
    case leading
    case center
    case trailing
}

public struct MarkdownTable: Equatable, Sendable {
    public var header: [String]
    public var alignments: [MarkdownTableAlignment]
    /// Body rows. Header, alignments and every row share one column count.
    public var rows: [[String]]

    public var columnCount: Int { header.count }

    public init(header: [String], alignments: [MarkdownTableAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

// MARK: - Parser

/// A small, line-based block parser for assistant replies: ATX/setext
/// headings, paragraphs, bullet/ordered/task lists with nesting, fenced code,
/// GFM tables, block quotes and thematic breaks.
///
/// It follows CommonMark/GFM where replies depend on it, and is deliberately
/// lenient where models are sloppy (nested lists indented by two spaces under
/// "1.", tables whose delimiter row has the wrong cell count). Replies are
/// parsed while they stream in, so every construct tolerates being cut off
/// mid-way: an unclosed fence is still a code block, a table whose delimiter
/// row is half-written is still a table, and no input is ever dropped.
public enum MarkdownBlockParser {
    /// Lists and quotes nest at most this deep; anything below is kept as
    /// plain paragraph text so pathological input can't build a view tree
    /// (or a recursion) of unbounded depth.
    static let maxNestingDepth = 6

    public static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.isEmpty else { return [] }
        // "\r\n" is a single Character in Swift, so neither a Character
        // search nor split(separator: "\n") would see it; check the scalars.
        let normalized = text.unicodeScalars.contains("\r")
            ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : text
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(expandLeadingTabs)
        return parseBlocks(lines, depth: 0)
    }

    // MARK: Block loop

    private static func parseBlocks(_ lines: [String], depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                flushParagraph()
                i += 1
                continue
            }
            if let fence = openingFence(line) {
                flushParagraph()
                let (block, next) = parseFencedCode(lines, at: i, fence: fence)
                blocks.append(block)
                i = next
                continue
            }
            if !paragraph.isEmpty, let level = setextLevel(line) {
                blocks.append(.heading(level: level, text: paragraph.joined(separator: " ")))
                paragraph.removeAll()
                i += 1
                continue
            }
            if let heading = atxHeading(line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }
            if isThematicBreak(line) {
                flushParagraph()
                blocks.append(.thematicBreak)
                i += 1
                continue
            }
            if let (table, next) = parseTable(lines, at: i) {
                flushParagraph()
                blocks.append(.table(table))
                i = next
                continue
            }
            if quoteContent(line) != nil {
                flushParagraph()
                let (block, next) = parseQuote(lines, at: i, depth: depth)
                blocks.append(block)
                i = next
                continue
            }
            if let marker = listMarker(line), paragraph.isEmpty || marker.canInterruptParagraph {
                flushParagraph()
                let (block, next) = parseList(lines, at: i, first: marker, depth: depth)
                blocks.append(block)
                i = next
                continue
            }
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// True when `lines[index]` opens a block that ends a lazy continuation
    /// (the unindented follow-on lines a list item or quote may absorb).
    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        return openingFence(line) != nil
            || atxHeading(line) != nil
            || isThematicBreak(line)
            || quoteContent(line) != nil
            || listMarker(line) != nil
            || tableHeader(lines, at: index) != nil
    }

    /// Whether a line leaves an open paragraph behind it — the precondition
    /// for the next line to be a lazy continuation of that paragraph.
    private static func continuesParagraph(_ line: String) -> Bool {
        !isBlank(line) && openingFence(line) == nil && atxHeading(line) == nil && !isThematicBreak(line)
    }

    // MARK: Fenced code

    struct Fence: Equatable {
        let marker: Character
        let length: Int
        let indent: Int
        let info: String
    }

    static func openingFence(_ line: String) -> Fence? {
        let indent = indentation(of: line)
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // ```code``` on one line is an inline code span, not a fence.
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, length: length, indent: indent, info: info)
    }

    static func closesFence(_ line: String, _ fence: Fence) -> Bool {
        // CommonMark caps the closing fence's indent at three spaces; models
        // indent it to match whatever the code sat under, so accept any.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.marker }
    }

    private static func parseFencedCode(_ lines: [String], at start: Int, fence: Fence) -> (MarkdownBlock, Int) {
        var body: [String] = []
        var closed = false
        var i = start + 1
        while i < lines.count {
            if closesFence(lines[i], fence) {
                closed = true
                i += 1
                break
            }
            body.append(dropIndent(lines[i], upTo: fence.indent))
            i += 1
        }
        // Trailing blank lines only add dead space under the code; streaming
        // replies produce them whenever a chunk ends right after a newline.
        while let last = body.last, isBlank(last) { body.removeLast() }
        let language = fence.info
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)
        let block = MarkdownCodeBlock(language: language, code: body.joined(separator: "\n"), isClosed: closed)
        return (.code(block), i)
    }

    // MARK: Headings, breaks

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indent = indentation(of: line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        // "#hashtag" is text; a heading needs whitespace (or nothing) after the #s.
        if let first = after.first, first != " ", first != "\t" { return nil }
        let text = after.trimmingCharacters(in: .whitespaces)
        if text.allSatisfy({ $0 == "#" }) { return (level, "") }
        return (level, String(droppingClosingSequence(text)))
    }

    /// "Title ##" → "Title": a closing run of `#`s counts only after a space
    /// or tab ("C#" keeps its #). Scans back from the end once — the regex
    /// `[ \t]+#+$` this replaces retried from every blank, quadratic in a long
    /// run of spaces, and parsing runs on the main thread.
    private static func droppingClosingSequence(_ text: String) -> Substring {
        var hashesStart = text.endIndex
        while hashesStart > text.startIndex, text[text.index(before: hashesStart)] == "#" {
            hashesStart = text.index(before: hashesStart)
        }
        guard hashesStart < text.endIndex, hashesStart > text.startIndex else { return text[...] }
        var contentEnd = hashesStart
        while contentEnd > text.startIndex {
            let previous = text.index(before: contentEnd)
            guard text[previous] == " " || text[previous] == "\t" else { break }
            contentEnd = previous
        }
        return contentEnd < hashesStart ? text[..<contentEnd] : text[...]
    }

    /// `===` / `---` under a paragraph. CommonMark accepts a single `-`, but
    /// that's also how every streamed bullet list starts ("Files:\n-"), which
    /// would flash the line above as a heading; require three characters.
    private static func setextLevel(_ line: String) -> Int? {
        guard indentation(of: line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indentation(of: line) <= 3 else { return false }
        var marker: Character?
        var count = 0
        for ch in line where ch != " " && ch != "\t" {
            guard ch == "-" || ch == "*" || ch == "_" else { return false }
            if let marker, marker != ch { return false }
            marker = ch
            count += 1
        }
        return count >= 3
    }

    // MARK: Block quotes

    /// The line's content after its `>` marker, or nil for a non-quote line.
    private static func quoteContent(_ line: String) -> String? {
        let indent = indentation(of: line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard rest.first == ">" else { return nil }
        var content = rest.dropFirst()
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }

    private static func parseQuote(_ lines: [String], at start: Int, depth: Int) -> (MarkdownBlock, Int) {
        var body: [String] = []
        var i = start
        var lazyAllowed = false
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { break }
            if let content = quoteContent(line) {
                body.append(content)
                lazyAllowed = continuesParagraph(content)
            } else if lazyAllowed && !startsBlock(lines, at: i) {
                body.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                break
            }
            i += 1
        }
        guard depth + 1 < maxNestingDepth else {
            return (.quote(flattenedParagraph(body)), i)
        }
        return (.quote(parseBlocks(body, depth: depth + 1)), i)
    }

    // MARK: Lists

    struct ListMarker: Equatable {
        let indent: Int
        let isOrdered: Bool
        let number: Int
        /// Column where the item's content starts; continuation lines
        /// indented this far belong to the item.
        let contentOffset: Int
        let content: String

        /// CommonMark: a list may interrupt a paragraph only with a non-empty
        /// item, and an ordered one only when it starts at 1 — otherwise
        /// "…was released in\n2024. It…" would turn into a list.
        var canInterruptParagraph: Bool {
            !content.isEmpty && (!isOrdered || number == 1)
        }
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentation(of: line)
        let rest = line.dropFirst(indent)
        // Called on nearly every line, often more than once: look at just
        // enough characters for the longest marker ("123456789.") and its
        // space instead of copying whole paragraphs.
        let head = Array(rest.prefix(11))
        guard let first = head.first else { return nil }

        var markerWidth: Int
        var isOrdered = false
        var number = 1
        if first == "-" || first == "*" || first == "+" {
            markerWidth = 1
        } else if first.isASCII, first.isNumber {
            var digits = 0
            while digits < head.count, digits < 9, head[digits].isASCII, head[digits].isNumber { digits += 1 }
            guard digits < head.count, head[digits] == "." || head[digits] == ")" else { return nil }
            number = Int(String(head[0..<digits])) ?? 1
            markerWidth = digits + 1
            isOrdered = true
        } else {
            return nil
        }
        // "**bold**", "-1", "1.5x": the marker must be followed by whitespace.
        if markerWidth < head.count, head[markerWidth] != " ", head[markerWidth] != "\t" { return nil }

        let afterMarker = rest.dropFirst(markerWidth)
        let spaces = afterMarker.prefix { $0 == " " || $0 == "\t" }.count
        let content = afterMarker.dropFirst(spaces).trimmingCharacters(in: .whitespaces)
        // Five or more spaces would make the content an indented code block in
        // CommonMark; we don't render those, so count just the one space.
        let padding = (spaces == 0 || spaces > 4 || content.isEmpty) ? 1 : spaces
        return ListMarker(
            indent: indent,
            isOrdered: isOrdered,
            number: number,
            contentOffset: indent + markerWidth + padding,
            content: content
        )
    }

    private static func parseList(_ lines: [String], at start: Int, first: ListMarker, depth: Int) -> (MarkdownBlock, Int) {
        var items: [MarkdownListItem] = []
        var marker = first
        var i = start
        while true {
            let (body, next) = collectItemLines(lines, at: i, marker: marker)
            items.append(makeItem(body, depth: depth))
            i = next

            // Blank lines between items make a loose list, not a new one.
            var k = next
            while k < lines.count, isBlank(lines[k]) { k += 1 }
            guard k < lines.count,
                  !isThematicBreak(lines[k]),
                  let sibling = listMarker(lines[k]),
                  sibling.isOrdered == first.isOrdered else { break }
            marker = sibling
            i = k
        }
        return (.list(MarkdownList(isOrdered: first.isOrdered, start: first.number, items: items)), i)
    }

    /// Gathers one item's lines, dedented, starting with the text after its
    /// marker. Returns the index of the first line that isn't part of it.
    private static func collectItemLines(_ lines: [String], at start: Int, marker: ListMarker) -> ([String], Int) {
        // CommonMark nests a child only once it reaches the parent's content
        // column ("1. " → 3). Models routinely nest by two spaces whatever the
        // marker width, so two past the marker is enough too.
        let childIndent = min(marker.contentOffset, marker.indent + 2)
        var body = [marker.content]
        var openFence = openingFence(marker.content)
        var lazyAllowed = openFence == nil && continuesParagraph(marker.content)
        var pendingBlanks = 0
        var i = start + 1

        while i < lines.count {
            let line = lines[i]
            if let fence = openFence {
                // Everything up to the closing fence is code, however it's
                // indented: an under-indented sample must not escape the item
                // and leave its closing fence to re-open as a runaway block.
                body.append(contentsOf: repeatElement("", count: pendingBlanks))
                pendingBlanks = 0
                body.append(dropIndent(line, upTo: childIndent))
                if closesFence(line, fence) { openFence = nil }
                lazyAllowed = false
                i += 1
                continue
            }
            if isBlank(line) {
                pendingBlanks += 1
                i += 1
                continue
            }
            if indentation(of: line) >= childIndent {
                body.append(contentsOf: repeatElement("", count: pendingBlanks))
                pendingBlanks = 0
                let dedented = dropIndent(line, upTo: childIndent)
                body.append(dedented)
                openFence = openingFence(dedented)
                lazyAllowed = openFence == nil && continuesParagraph(dedented)
                i += 1
                continue
            }
            if pendingBlanks == 0, lazyAllowed, !startsBlock(lines, at: i) {
                body.append(line.trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            break
        }
        // Trailing blank lines separate this item from what follows; leave
        // them for the caller.
        return (body, i - pendingBlanks)
    }

    private static func makeItem(_ lines: [String], depth: Int) -> MarkdownListItem {
        var lines = lines
        var checkbox: MarkdownListItem.Checkbox?
        if let first = lines.first, let (box, rest) = taskCheckbox(first) {
            checkbox = box
            lines[0] = rest
        }
        guard depth + 1 < maxNestingDepth else {
            return MarkdownListItem(checkbox: checkbox, blocks: flattenedParagraph(lines))
        }
        return MarkdownListItem(checkbox: checkbox, blocks: parseBlocks(lines, depth: depth + 1))
    }

    private static func taskCheckbox(_ content: String) -> (MarkdownListItem.Checkbox, String)? {
        guard content.count >= 3, content.hasPrefix("[") else { return nil }
        let chars = Array(content.prefix(4))
        guard chars[2] == "]" else { return nil }
        let box: MarkdownListItem.Checkbox
        switch chars[1] {
        case " ": box = .unchecked
        case "x", "X": box = .checked
        default: return nil
        }
        // "[x]" must stand alone or be followed by whitespace; "[x](url)" is a link.
        if chars.count == 4, chars[3] != " ", chars[3] != "\t" { return nil }
        return (box, String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Tables

    /// Header cells and alignments when `lines[index]` starts a GFM table:
    /// a row with a pipe followed by a delimiter row (`| --- | :-: |`).
    private static func tableHeader(_ lines: [String], at index: Int) -> (cells: [String], alignments: [MarkdownTableAlignment])? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        guard headerLine.contains("|"), indentation(of: headerLine) <= 3 else { return nil }
        let delimiterLine = lines[index + 1]
        guard delimiterLine.contains("|"),
              delimiterLine.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " || $0 == "\t" }) else {
            return nil
        }
        let delimiterCells = splitRow(delimiterLine)
        var alignments: [MarkdownTableAlignment] = []
        var complete = true
        for cell in delimiterCells {
            if let alignment = delimiterAlignment(cell) {
                alignments.append(alignment)
            } else {
                complete = false
                alignments.append(.automatic)
            }
        }
        // A streaming reply ends mid-delimiter ("|---|--" or just "|") until
        // the next chunk lands; show the table already rather than flashing
        // raw pipes. Any earlier line has to be a well-formed delimiter.
        let isLastLine = index + 1 == lines.count - 1
        guard complete || isLastLine else { return nil }
        return (splitRow(headerLine), alignments)
    }

    private static func delimiterAlignment(_ cell: String) -> MarkdownTableAlignment? {
        let leading = cell.hasPrefix(":")
        let trailing = cell.count > 1 && cell.hasSuffix(":")
        let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        switch (leading, trailing) {
        case (true, true): return .center
        case (true, false): return .leading
        case (false, true): return .trailing
        case (false, false): return .automatic
        }
    }

    private static func parseTable(_ lines: [String], at start: Int) -> (MarkdownTable, Int)? {
        guard let (header, delimiterAlignments) = tableHeader(lines, at: start) else { return nil }
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let line = lines[i]
            guard !isBlank(line), line.contains("|"),
                  openingFence(line) == nil, atxHeading(line) == nil, quoteContent(line) == nil else { break }
            rows.append(splitRow(line))
            i += 1
        }
        // GFM clips cells beyond the header's count; widen the table instead
        // so a model's miscounted row never silently loses content — up to
        // maxTableColumns: a stray line of pipes would otherwise make
        // hundreds of columns and tens of thousands of cells.
        let widest = ([header.count, delimiterAlignments.count] + rows.map(\.count)).max() ?? 0
        let columnCount = min(widest, maxTableColumns)
        func fitted(_ cells: [String]) -> [String] {
            guard cells.count > columnCount else {
                return cells + Array(repeating: "", count: columnCount - cells.count)
            }
            // The overflow stays readable in the last column, pipes and all.
            let kept = cells.prefix(columnCount - 1)
            let rest = cells.dropFirst(columnCount - 1).filter { !$0.isEmpty }
            return Array(kept) + [rest.joined(separator: " | ")]
        }
        let alignments = Array(delimiterAlignments.prefix(columnCount))
        let table = MarkdownTable(
            header: fitted(header),
            alignments: alignments + Array(repeating: .automatic, count: columnCount - alignments.count),
            rows: rows.map(fitted)
        )
        return (table, i)
    }

    /// Widest table the parser builds; cells past it join the last column.
    static let maxTableColumns = 16

    /// Splits a table row on unescaped pipes. Pipes inside `code spans` stay
    /// in their cell even unescaped — GFM would split there, but models write
    /// `a | b` in code all the time and a torn cell is worse than a lenient one.
    static func splitRow(_ line: String) -> [String] {
        var row = Substring(line.trimmingCharacters(in: .whitespaces))
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }

        let chars = Array(row)
        var cells: [String] = []
        var current = ""
        var k = 0
        while k < chars.count {
            let ch = chars[k]
            if ch == "\\", k + 1 < chars.count, chars[k + 1] == "|" {
                current.append("|")
                k += 2
            } else if ch == "`" {
                var run = 0
                while k + run < chars.count, chars[k + run] == "`" { run += 1 }
                let end = closingBacktickRun(chars, from: k + run, length: run).map { $0 + run } ?? k + run
                current.append(String(chars[k..<end]).replacingOccurrences(of: "\\|", with: "|"))
                k = end
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                k += 1
            } else {
                current.append(ch)
                k += 1
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func closingBacktickRun(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var k = start
        while k < chars.count {
            guard chars[k] == "`" else {
                k += 1
                continue
            }
            var run = 0
            while k + run < chars.count, chars[k + run] == "`" { run += 1 }
            if run == length { return k }
            k += run
        }
        return nil
    }

    // MARK: Helpers

    private static func flattenedParagraph(_ lines: [String]) -> [MarkdownBlock] {
        let text = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? [] : [.paragraph(text)]
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func indentation(of line: String) -> Int {
        var count = 0
        for ch in line {
            guard ch == " " else { break }
            count += 1
        }
        return count
    }

    private static func dropIndent(_ line: String, upTo limit: Int) -> String {
        var dropped = 0
        var index = line.startIndex
        while dropped < limit, index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
            dropped += 1
        }
        return String(line[index...])
    }

    /// Leading tabs become spaces (to the next multiple of four) so
    /// indentation can be compared by counting spaces alone.
    private static func expandLeadingTabs(_ line: Substring) -> String {
        guard line.first == " " || line.first == "\t", line.contains("\t") else { return String(line) }
        var prefix = ""
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            if line[index] == "\t" {
                prefix += String(repeating: " ", count: 4 - prefix.count % 4)
            } else {
                prefix += " "
            }
            index = line.index(after: index)
        }
        return prefix + line[index...]
    }
}
