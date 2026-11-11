import Foundation

public enum ChatMessageTextFormatter {
    /// Streaming replies produce a new key per chunk, so every cache is
    /// bounded by entry count and by the bytes of text it holds.
    private static let cacheCountLimit = 128
    private static var markdownCache = TextRenderCache<String, AttributedString>(countLimit: cacheCountLimit)
    // Separate from markdownCache: inlineMarkdown() also splits fences, so the
    // same key can render differently there.
    private static var inlineSpanCache = TextRenderCache<String, AttributedString>(countLimit: cacheCountLimit)
    private static var blockCache = TextRenderCache<String, [MarkdownBlock]>(countLimit: cacheCountLimit)
    private static var previewCache = TextRenderCache<PreviewKey, AttributedString>(
        countLimit: cacheCountLimit,
        cost: { $0.text.utf8.count }
    )

    private struct PreviewKey: Hashable {
        let text: String
        let singleLine: Bool
    }

    /// Bytes of source text each cache holds, for tests.
    static var cachedTextBytes: [Int] {
        [markdownCache.byteCount, inlineSpanCache.byteCount, blockCache.byteCount, previewCache.byteCount]
    }

    public static func displayText(for message: ChatMessage) -> AttributedString {
        message.isUser ? literalText(message.text) : inlineMarkdown(message.text)
    }

    public static func literalText(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    public static func inlineMarkdown(_ text: String) -> AttributedString {
        markdownCache.value(for: text) {
            text.contains("```") ? renderWithFencedCodeBlocks(text) : renderInlineOnly(text)
        }
    }

    /// Inline spans only (bold, italic, code, links, strikethrough) with
    /// whitespace preserved — the per-block renderer for text that
    /// MarkdownBlockParser has already split out of its block syntax.
    public static func inlineSpans(_ text: String) -> AttributedString {
        inlineSpanCache.value(for: text) { renderInlineOnly(text) }
    }

    /// Block structure of an assistant reply. Cached because the island
    /// re-evaluates card bodies on hover and during expand animations, while
    /// the reply text itself rarely changes between those passes.
    public static func markdownBlocks(_ text: String) -> [MarkdownBlock] {
        blockCache.value(for: text) { MarkdownBlockParser.parse(text) }
    }

    /// Clean, marker-free preview of a reply for line-capped rows. See
    /// MarkdownPreviewText. Only the reply's head is flattened
    /// (MarkdownPreviewText.previewSource): a preview can't show more.
    public static func markdownPreview(_ text: String, singleLine: Bool) -> AttributedString {
        let source = MarkdownPreviewText.previewSource(text)
        return previewCache.value(for: PreviewKey(text: source, singleLine: singleLine)) {
            MarkdownPreviewText.attributed(markdownBlocks(source), singleLine: singleLine)
        }
    }

    /// Apple's inline-only markdown parser treats ``` as inline code delimiters, which collapses
    /// fenced code blocks and leaks the language identifier into the text (issue #101). Split the
    /// input around fence markers and render code bodies literally, preserving newlines.
    private static func renderWithFencedCodeBlocks(_ text: String) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var inFence = false
        var hasOutput = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let piece = inFence ? AttributedString(buffer) : renderInlineOnly(buffer)
            if hasOutput {
                result.append(AttributedString("\n"))
            }
            result.append(piece)
            hasOutput = true
            buffer = ""
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inFence.toggle()
                continue
            }
            if !buffer.isEmpty { buffer.append("\n") }
            buffer.append(line)
        }
        flush()
        return result
    }

    /// `*`, `_` and `~` inside a word stay literal — see MarkdownInlineLiterals.
    private static func renderInlineOnly(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: MarkdownInlineLiterals.escapingWordDelimiters(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }
}
