import Foundation

/// Folds a reply's block structure into clean running text for line-capped
/// previews (the "AI Reply Lines" setting and other one-line summaries).
///
/// A preview cut to one or a few lines can't show a table or a code block —
/// it can only show their syntax: `## `, `- [ ]`, `| --- |`, ```` ```swift ````.
/// Instead, every block is reduced to its words: headings lose their `#`,
/// list items are joined with " · ", table rows become "cell, cell", a code
/// block shows its first line, and inline spans are rendered (bold stays bold,
/// `**` disappears).
public enum MarkdownPreviewText {
    /// Joins list items, table rows and — in single-line mode — blocks.
    public static let separator = " · "

    /// - Parameter singleLine: when true everything lands on one line;
    ///   otherwise each block keeps its own line so a multi-line preview
    ///   still reads top-down.
    public static func attributed(_ blocks: [MarkdownBlock], singleLine: Bool) -> AttributedString {
        join(segments(of: blocks, singleLine: singleLine), singleLine: singleLine)
    }

    public static func plain(_ text: String, singleLine: Bool) -> String {
        String(attributed(MarkdownBlockParser.parse(text), singleLine: singleLine).characters)
    }

    // MARK: - Source budget

    /// Bytes of text outside code fences worth flattening. A preview shows
    /// a few lines at most — the island caps rows at five, the iPhone and
    /// Watch take 240 characters, the Codex live bar 160 — while flattening
    /// parses and inline-renders the whole reply: ~120ms for a 139 KB Codex
    /// output, redone for every streamed chunk, on the main thread.
    public static let sourceBudget = 8 * 1024
    /// Bytes in all, code included. Code only contributes its first line to
    /// a preview, so it doesn't count against `sourceBudget` — a long sample
    /// can't hide the text after it — but an unclosed fence must still end.
    public static let sourceHardLimit = 64 * 1024

    /// The head of `text` a preview is built from: whole lines up to the
    /// budget, then as much of the next line as fits. Short replies come
    /// back unchanged.
    public static func previewSource(_ text: String) -> String {
        guard text.utf8.count > sourceBudget else { return text }
        var prose = 0
        var total = 0
        var fence: MarkdownBlockParser.Fence?
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text.utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let bytes = line.utf8.count
            var isProse = false
            if let open = fence {
                if MarkdownBlockParser.closesFence(String(line), open) { fence = nil }
            } else if let open = openingFence(line) {
                fence = open
            } else {
                isProse = true
            }
            let allowance = isProse
                ? min(sourceBudget - prose, sourceHardLimit - total)
                : sourceHardLimit - total
            if bytes > allowance {
                return String(text[..<lineStart]) + String(line.prefix(max(0, allowance)))
            }
            if isProse { prose += bytes }
            total += bytes + 1
            guard lineEnd < text.endIndex else { break }
            lineStart = text.utf8.index(after: lineEnd)
        }
        return text
    }

    private static func openingFence(_ line: Substring) -> MarkdownBlockParser.Fence? {
        guard let first = line.first(where: { $0 != " " && $0 != "\t" }), first == "`" || first == "~" else {
            return nil
        }
        return MarkdownBlockParser.openingFence(String(line))
    }

    // MARK: - Segments

    /// One segment per block, already inline-rendered. Empty blocks (a lone
    /// `#` mid-stream, a thematic break) produce nothing.
    private static func segments(of blocks: [MarkdownBlock], singleLine: Bool) -> [AttributedString] {
        var result: [AttributedString] = []
        for block in blocks {
            switch block {
            case .heading(_, let text):
                var heading = inline(text, singleLine: true)
                // Keep a heading recognisable once its `#` is gone.
                let runs = heading.runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
                for (range, intent) in runs {
                    heading[range].inlinePresentationIntent = intent.union(.stronglyEmphasized)
                }
                result.append(heading)
            case .paragraph(let text):
                result.append(inline(text, singleLine: singleLine))
            case .list(let list):
                result.append(join(listItems(list), with: separator))
            case .code(let code):
                result.append(codeSummary(code))
            case .table(let table):
                let rows = ([table.header] + table.rows).map { row in
                    join(row.filter { !isBlank($0) }.map { inline($0, singleLine: true) }, with: ", ")
                }
                result.append(join(rows, with: separator))
            case .quote(let inner):
                result.append(contentsOf: segments(of: inner, singleLine: singleLine))
            case .thematicBreak:
                continue
            }
        }
        return result.filter { !isBlank(String($0.characters)) }
    }

    private static func listItems(_ list: MarkdownList) -> [AttributedString] {
        list.items.enumerated().compactMap { index, item in
            // An item's own paragraph and its nested list flow into one run:
            // "Parent · child · child".
            var text = join(segments(of: item.blocks, singleLine: true), singleLine: true)
            if let box = item.checkbox {
                text = AttributedString(box == .checked ? "☑ " : "☐ ") + text
            }
            // Numbers carry meaning (steps, ranking); bullets don't.
            if list.isOrdered {
                text = AttributedString("\(list.start + index). ") + text
            }
            return isBlank(String(text.characters)) ? nil : text
        }
    }

    /// First non-empty line of the code, styled as code, plus an ellipsis when
    /// more follows — enough to recognise `npm test` without spilling a whole
    /// script into the preview.
    private static func codeSummary(_ code: MarkdownCodeBlock) -> AttributedString {
        let lines = code.code
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return AttributedString() }
        var summary = AttributedString(first)
        summary.inlinePresentationIntent = .code
        if lines.count > 1 {
            summary += AttributedString(" …")
        }
        return summary
    }

    // MARK: - Joining

    private static func join(_ segments: [AttributedString], singleLine: Bool) -> AttributedString {
        guard singleLine else { return join(segments, with: "\n") }
        var result = AttributedString()
        for segment in segments {
            if !result.characters.isEmpty {
                // "Changes:" already introduces what follows; a dot after it reads as noise.
                let last = result.characters.last
                result += AttributedString(last == ":" || last == "：" ? " " : separator)
            }
            result += segment
        }
        return result
    }

    private static func join(_ segments: [AttributedString], with separator: String) -> AttributedString {
        var result = AttributedString()
        for segment in segments where !segment.characters.isEmpty {
            if !result.characters.isEmpty {
                result += AttributedString(separator)
            }
            result += segment
        }
        return result
    }

    private static func inline(_ text: String, singleLine: Bool) -> AttributedString {
        let source = singleLine ? text.replacingOccurrences(of: "\n", with: " ") : text
        return ChatMessageTextFormatter.inlineSpans(source)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
