import Foundation

/// Keeps `*`, `_` and `~` that belong to a word literal before a reply's
/// text reaches Apple's inline Markdown parser.
///
/// CommonMark lets `*` emphasise inside a word and GFM strikes text through
/// with a single `~`, so the parser turns `2*3*4 = 24` into 2*3*4 with the
/// 3 in italics, `__init__.py` into a bold "init" followed by ".py", and
/// `~/code … a~b~c` into a strikethrough — the markers vanish and the text
/// says something else. On the island that loses characters from previews;
/// on the iPhone, Watch and Buddy, which get the plain characters, it loses
/// them outright. Replies write arithmetic, globs, dunder names and home
/// paths far more often than emphasis in the middle of a word.
///
/// So a delimiter run that could neither open emphasis at the start of a
/// word nor close it at the end of one is escaped: looking outward past
/// punctuation, it touches a Latin letter or digit on both sides. Runs at a
/// word boundary — `**Note**:`, `(**bold**)`, and CJK text, which puts no
/// spaces between words (`这是**重点**内容`) — are left to the parser. Code
/// spans, backslash escapes and link-like tokens (URLs, e-mail addresses,
/// which the parser autolinks) pass through untouched.
enum MarkdownInlineLiterals {
    static func escapingWordDelimiters(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == UInt8(ascii: "*") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "~") }) else {
            return text
        }
        let scalars = Array(text.unicodeScalars)
        var closers = BacktickRuns(scalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count + 8)
        var i = 0
        var verbatimEnd = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if i < verbatimEnd {
                out.append(scalar)
                i += 1
                continue
            }
            if i == 0 || isWhitespace(scalars[i - 1]), let end = linkLikeToken(scalars, from: i) {
                verbatimEnd = end
                continue
            }
            switch scalar {
            case "\\":
                out.append(contentsOf: scalars[i..<min(i + 2, scalars.count)])
                i += 2
            case "`":
                var end = i
                while end < scalars.count, scalars[end] == "`" { end += 1 }
                let length = end - i
                // A code span runs to the next backtick run of the same
                // length; without one the backticks are literal.
                let spanEnd = closers.next(length: length, from: end).map { $0 + length } ?? end
                out.append(contentsOf: scalars[i..<spanEnd])
                i = spanEnd
            case "*", "_", "~":
                var end = i
                while end < scalars.count, scalars[end] == scalar { end += 1 }
                let literal = !opensAtWordBoundary(scalars, runStart: i) && !closesAtWordBoundary(scalars, runEnd: end)
                    || scalar == "_" && end - i == 2 && isDunderName(scalars, openingRunEnd: end)
                for _ in i..<end {
                    if literal { out.append("\\") }
                    out.append(scalar)
                }
                i = end
            default:
                out.append(scalar)
                i += 1
            }
        }
        return String(out)
    }

    // MARK: - Word boundaries

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII ? scalar.value <= 0x20 : scalar.properties.isWhitespace
    }

    private enum Neighbour {
        /// Whitespace, the text's edge, or a letter of a script written
        /// without spaces between words.
        case boundary
        /// A Latin letter or digit.
        case word
        /// Punctuation and symbols: look past them.
        case punctuation
    }

    private static func neighbour(_ scalar: Unicode.Scalar) -> Neighbour {
        if scalar.isASCII {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return .word
            case 0x00...0x20, 0x7F: return .boundary
            default: return .punctuation
            }
        }
        if isWhitespace(scalar) { return .boundary }
        let properties = scalar.properties
        // Latin-1 Supplement and Latin Extended-A/B letters (é, ß, ł, …).
        if (0xC0...0x24F).contains(scalar.value), properties.isAlphabetic { return .word }
        switch properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return .punctuation
        default:
            return .boundary
        }
    }

    /// Punctuation looked past before giving up and treating the run as at a
    /// boundary — keeps the scan linear on a line of `*.*.*.*…`.
    private static let punctuationLookaround = 16

    private static func opensAtWordBoundary(_ scalars: [Unicode.Scalar], runStart: Int) -> Bool {
        var k = runStart - 1
        var skipped = 0
        while k >= 0, skipped < punctuationLookaround {
            switch neighbour(scalars[k]) {
            case .word: return false
            case .boundary: return true
            case .punctuation:
                k -= 1
                skipped += 1
            }
        }
        return true
    }

    private static func closesAtWordBoundary(_ scalars: [Unicode.Scalar], runEnd: Int) -> Bool {
        var k = runEnd
        var skipped = 0
        while k < scalars.count, skipped < punctuationLookaround {
            switch neighbour(scalars[k]) {
            case .word: return false
            case .boundary: return true
            case .punctuation:
                k += 1
                skipped += 1
            }
        }
        return true
    }

    /// `__init__`, `__name__`: Python's dunder names, which replies write
    /// bare far more often than they write `__bold__`. Escaping the opening
    /// run is enough to keep both runs literal.
    private static func isDunderName(_ scalars: [Unicode.Scalar], openingRunEnd: Int) -> Bool {
        var k = openingRunEnd
        while k < scalars.count {
            let scalar = scalars[k]
            if scalar == "_" {
                if k + 1 < scalars.count, scalars[k + 1] == "_" { break }
            } else if !(scalar.isASCII && neighbour(scalar) == .word) {
                return false
            }
            k += 1
        }
        guard k > openingRunEnd, k + 1 < scalars.count else { return false }
        // Exactly two underscores close it, followed by no more name.
        let after = k + 2
        return after == scalars.count || (scalars[after] != "_" && neighbour(scalars[after]) != .word)
    }

    // MARK: - Tokens the parser autolinks

    /// End of the whitespace-delimited token starting at `start` when it is
    /// a URL or an e-mail address. The parser links those itself, and an
    /// escape inside one would end up in the link.
    private static func linkLikeToken(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var end = start
        var hasAt = false
        var hasScheme = false
        while end < scalars.count, !isWhitespace(scalars[end]) {
            switch scalars[end] {
            // A backtick may open a code span that runs past this token;
            // the code-span scan has to see it.
            case "`": return nil
            case "@": hasAt = true
            case ":":
                if end + 2 < scalars.count, scalars[end + 1] == "/", scalars[end + 2] == "/" { hasScheme = true }
            default: break
            }
            end += 1
        }
        let token = String(String.UnicodeScalarView(scalars[start..<end]))
        guard hasScheme || hasAt || token.lowercased().hasPrefix("www.") else { return nil }
        return end
    }

    // MARK: - Code spans

    /// Every backtick run in the text by length, so finding a code span's
    /// closer is a lookup rather than a rescan — a reply full of unmatched
    /// backticks stays linear.
    private struct BacktickRuns {
        private var starts: [Int: [Int]] = [:]
        private var cursors: [Int: Int] = [:]

        init(_ scalars: [Unicode.Scalar]) {
            var k = 0
            while k < scalars.count {
                guard scalars[k] == "`" else {
                    k += 1
                    continue
                }
                var end = k
                while end < scalars.count, scalars[end] == "`" { end += 1 }
                starts[end - k, default: []].append(k)
                k = end
            }
        }

        /// First run of exactly `length` backticks starting at or after
        /// `position`. Positions only grow, so each length's cursor only
        /// moves forward.
        mutating func next(length: Int, from position: Int) -> Int? {
            guard let runs = starts[length] else { return nil }
            var k = cursors[length] ?? 0
            while k < runs.count, runs[k] < position { k += 1 }
            cursors[length] = k
            return k < runs.count ? runs[k] : nil
        }
    }
}
