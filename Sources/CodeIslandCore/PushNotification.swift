import Foundation

// MARK: - What a push is about

/// The moments worth reaching for a phone over. One push per moment, not per
/// hook: a burst of hooks for the same session collapses into one push
/// (see `PushDeduplicator`).
public enum PushEventKind: String, CaseIterable, Codable, Sendable {
    case permission
    case question
    case completion
    case error
    /// Follow-up for an approval / question still unanswered, or a finished
    /// turn nobody looked at. Raised by `FollowUpReminderController`, never
    /// by a hook.
    case reminder

    /// Kinds that keep an agent blocked until someone answers. Channels map
    /// this onto their own "break through" knob (Bark time-sensitive, ntfy
    /// high priority); a finished turn or an error can wait for the user.
    /// A reminder's own urgency follows what it reminds about
    /// (`PushContent.blocksAgent`).
    public var blocksAgent: Bool {
        switch self {
        case .permission, .question, .reminder: return true
        case .completion, .error: return false
        }
    }

    /// Kinds offered as per-channel checkboxes, in display order.
    public static let configurable: [PushEventKind] = [.permission, .question, .completion, .error, .reminder]

    /// What a freshly configured channel pushes.
    public static let defaultSelection: Set<PushEventKind> = Set(allCases)

    /// Scannable marker at the front of the title; lock screens truncate the
    /// rest, so the kind has to be readable from the first glyph.
    public var emoji: String {
        switch self {
        case .permission: return "🔐"
        case .question: return "❓"
        case .completion: return "✅"
        case .error: return "❌"
        case .reminder: return "⏰"
        }
    }
}

/// Who a push is about, read off the session card rather than guessed from
/// the raw hook payload.
public struct PushSubject: Equatable, Sendable {
    public var sessionId: String
    /// Display name of the agent ("Claude", "Codex").
    public var agent: String
    /// Project folder name.
    public var project: String?
    /// Remote host label for SSH sessions.
    public var host: String?

    public init(sessionId: String, agent: String, project: String? = nil, host: String? = nil) {
        self.sessionId = sessionId
        self.agent = agent
        self.project = project
        self.host = host
    }

    /// "Claude · vibe-notch", or "Claude · vibe-notch @ devbox" for a remote session.
    public var label: String {
        var parts = [agent.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let project = project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            parts.append(project)
        }
        var label = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        if let host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            label += " @ \(host)"
        }
        return label
    }
}

public struct PushQuestionItem: Hashable, Sendable {
    public var question: String
    public var options: [String]
    /// Short label of the question (AskUserQuestion's `header`, "Auth
    /// method") — all of it a headline-only push shows.
    public var header: String?

    public init(question: String, options: [String] = [], header: String? = nil) {
        self.question = question
        self.options = options
        self.header = header
    }
}

/// Structured content, taken from the same queue entries the island renders
/// (permissionQueue / questionQueue / the completion card), so the phone and
/// the notch never disagree about what is being asked.
public indirect enum PushContent: Hashable, Sendable {
    /// `detail`: command, file path or other one-line summary of the call.
    case permission(tool: String?, detail: String?)
    /// `isSecret`: the answer is sensitive (Codex `isSecret`); neither the
    /// question nor its options leave the Mac.
    case question(items: [PushQuestionItem], isSecret: Bool)
    /// `summary`: the last assistant reply of the turn.
    case completion(summary: String?)
    /// `type`: machine error class ("rate_limit"); `detail`: readable text.
    case error(type: String?, detail: String?)
    /// `pending`: what is still waiting (usually the original permission or
    /// question); `waitingSince`: when it started waiting.
    case reminder(pending: PushContent?, waitingSince: Date?)
    /// A display-only wait (`DisplayOnlyWait`): `pending` is what is asked
    /// (`.permission` / `.question`), `app` where it has to be answered — nil
    /// when unknown. Nothing on the island (or the phone) can answer it, and
    /// the push says so. It is an approval / question in every other respect:
    /// same kind, so the same channel checkboxes and dedupe apply.
    case answerElsewhere(pending: PushContent, app: String?)

    public var kind: PushEventKind {
        switch self {
        case .permission: return .permission
        case .question: return .question
        case .completion: return .completion
        case .error: return .error
        case .reminder: return .reminder
        case .answerElsewhere(let pending, _): return pending.kind
        }
    }

    /// A reminder about a finished turn must not break through Focus just
    /// because it is a reminder; one about an approval must.
    public var blocksAgent: Bool {
        switch self {
        case .reminder(let pending, _): return pending?.blocksAgent ?? true
        case .answerElsewhere(let pending, _): return pending.blocksAgent
        default: return kind.blocksAgent
        }
    }
}

/// Localized phrases. Core has no access to the app's L10n tables, so the
/// app passes these in; tests use `.english`.
public struct PushStrings: Equatable, Sendable {
    public var permission: String
    public var question: String
    public var completion: String
    public var error: String
    public var reminder: String
    /// `%d` = minutes waited.
    public var waitingMinutes: String
    public var secretQuestion: String
    /// `%d` = options left out.
    public var moreOptions: String
    public var testHeadline: String
    public var testBody: String
    /// `%@` = the app a display-only wait has to be answered in.
    public var answerIn: String
    /// A display-only wait whose app is unknown.
    public var answerOnMac: String

    public init(
        permission: String,
        question: String,
        completion: String,
        error: String,
        reminder: String,
        waitingMinutes: String,
        secretQuestion: String,
        moreOptions: String,
        testHeadline: String,
        testBody: String,
        answerIn: String = "Respond in %@.",
        answerOnMac: String = "Respond on your Mac."
    ) {
        self.permission = permission
        self.question = question
        self.completion = completion
        self.error = error
        self.reminder = reminder
        self.waitingMinutes = waitingMinutes
        self.secretQuestion = secretQuestion
        self.moreOptions = moreOptions
        self.testHeadline = testHeadline
        self.testBody = testBody
        self.answerIn = answerIn
        self.answerOnMac = answerOnMac
    }

    public static let english = PushStrings(
        permission: "Needs approval",
        question: "Has a question",
        completion: "Finished",
        error: "Stopped on an error",
        reminder: "Still waiting",
        waitingMinutes: "%d min",
        secretQuestion: "Sensitive prompt — answer it on your Mac.",
        moreOptions: "+%d more",
        testHeadline: "Test notification",
        testBody: "If you can read this, CodeIsland can reach you here.",
        answerIn: "Respond in %@.",
        answerOnMac: "Respond on your Mac."
    )
}

/// A rendered push, channel-neutral. Channels decide how the three parts map
/// onto their own fields (Bark has a subtitle slot; chat bots get lines).
public struct PushMessage: Equatable, Sendable {
    public var kind: PushEventKind
    public var sessionId: String
    /// Emoji + who: "🔐 Claude · vibe-notch".
    public var title: String
    /// What happened: "Needs approval: Bash".
    public var headline: String
    /// Details, possibly several lines; may be empty.
    public var body: String
    /// Rendered as time-sensitive / high priority.
    public var blocksAgent: Bool

    public init(
        kind: PushEventKind,
        sessionId: String,
        title: String,
        headline: String,
        body: String,
        blocksAgent: Bool? = nil
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.title = title
        self.headline = headline
        self.body = body
        self.blocksAgent = blocksAgent ?? kind.blocksAgent
    }

    /// Headline and body, for channels without a subtitle slot.
    public var text: String {
        [headline, body].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// What "Send test" delivers. Uses the permission styling so the test
    /// exercises the urgent path (Bark time-sensitive, ntfy high).
    public static func test(strings: PushStrings) -> PushMessage {
        PushMessage(
            kind: .permission,
            sessionId: "codeisland-test",
            title: "🔔 CodeIsland",
            headline: strings.testHeadline,
            body: strings.testBody
        )
    }
}

// MARK: - Rendering

public enum PushMessageFormatter {
    /// Commands and paths are recognisable from their first few hundred characters.
    public static let detailLimit = 300
    public static let questionLimit = 300
    public static let optionLimit = 80
    public static let maxOptions = 9
    public static let maxQuestions = 4
    /// Default cap on the completion summary; the user can change it.
    public static let defaultSummaryLimit = 200

    /// Longest question label a headline-only push shows.
    public static let headerLimit = 40

    /// - `includeDetails`: false renders the headline only — who, which
    ///   project, what happened and the tool name or question label — with no
    ///   command, reply, error text or options. Team chats default to it
    ///   (`PushChannelConfig.includeDetails`): everyone in the group reads them.
    public static func render(
        _ content: PushContent,
        subject: PushSubject,
        strings: PushStrings,
        summaryLimit: Int = defaultSummaryLimit,
        includeDetails: Bool = true,
        now: Date = Date()
    ) -> PushMessage {
        let parts = lines(
            for: content,
            strings: strings,
            summaryLimit: summaryLimit,
            includeDetails: includeDetails,
            now: now
        )
        let who = subject.label
        return PushMessage(
            kind: content.kind,
            sessionId: subject.sessionId,
            title: who.isEmpty ? content.kind.emoji : "\(content.kind.emoji) \(who)",
            headline: parts.headline,
            body: parts.body,
            blocksAgent: content.blocksAgent
        )
    }

    static func lines(
        for content: PushContent,
        strings: PushStrings,
        summaryLimit: Int,
        includeDetails: Bool = true,
        now: Date
    ) -> (headline: String, body: String) {
        switch content {
        case .permission(let tool, let detail):
            let toolName = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let headline = toolName.isEmpty ? strings.permission : "\(strings.permission): \(toolName)"
            guard includeDetails else { return (headline, "") }
            return (headline, clean(firstLine(of: detail), limit: detailLimit) ?? "")

        case .question(let items, let isSecret):
            // The card never streams a secret prompt to a peripheral either
            // (QuestionPayload.isSecret); a third-party push server is further
            // off-device than the Buddy.
            if isSecret { return (strings.question, strings.secretQuestion) }
            guard includeDetails else {
                let labels = items.compactMap { clean($0.header, limit: headerLimit) }
                let headline = labels.isEmpty
                    ? strings.question
                    : "\(strings.question): \(labels.joined(separator: " · "))"
                return (headline, "")
            }
            return (strings.question, questionBody(items, strings: strings))

        case .completion(let summary):
            guard includeDetails else { return (strings.completion, "") }
            return (strings.completion, clean(summary, limit: max(summaryLimit, 20), markdown: true) ?? "")

        case .error(let type, let detail):
            let type = type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let headline = type.isEmpty ? strings.error : "\(strings.error) (\(type))"
            guard includeDetails else { return (headline, "") }
            return (headline, clean(detail, limit: max(summaryLimit, 20), markdown: true) ?? "")

        case .reminder(let pending, let waitingSince):
            var headline = strings.reminder
            if let waitingSince {
                let minutes = Int(now.timeIntervalSince(waitingSince) / 60)
                if minutes >= 1 {
                    headline += " · " + String(format: strings.waitingMinutes, minutes)
                }
            }
            // A reminder about a reminder would only repeat the headline.
            guard let pending, pending.kind != .reminder else { return (headline, "") }
            let inner = lines(
                for: pending,
                strings: strings,
                summaryLimit: summaryLimit,
                includeDetails: includeDetails,
                now: now
            )
            let body = [inner.headline, inner.body].filter { !$0.isEmpty }.joined(separator: "\n")
            return (headline, body)

        case .answerElsewhere(let pending, let app):
            // What is asked reads exactly like an island approval / question;
            // the last line says where it has to be answered.
            let inner = lines(
                for: pending,
                strings: strings,
                summaryLimit: summaryLimit,
                includeDetails: includeDetails,
                now: now
            )
            let place = app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let whereTo = place.isEmpty ? strings.answerOnMac : String(format: strings.answerIn, place)
            let body = [inner.body, whereTo].filter { !$0.isEmpty }.joined(separator: "\n")
            return (inner.headline, body)
        }
    }

    /// "Which database?\n1. Postgres\n2. SQLite" — numbered so the reader can
    /// answer "2" at the Mac without re-reading the list. Several questions
    /// (AskUserQuestion wizards) are prefixed "(1/2)".
    static func questionBody(_ items: [PushQuestionItem], strings: PushStrings) -> String {
        let shown = items.prefix(maxQuestions)
        var lines: [String] = []
        for (index, item) in shown.enumerated() {
            let question = clean(item.question, limit: questionLimit, markdown: true) ?? ""
            let prefix = items.count > 1 ? "(\(index + 1)/\(items.count)) " : ""
            if !question.isEmpty || !prefix.isEmpty {
                lines.append(prefix + question)
            }
            let options = item.options.compactMap { clean($0, limit: optionLimit, markdown: true) }
            for (number, option) in options.prefix(maxOptions).enumerated() {
                lines.append("\(number + 1). \(option)")
            }
            if options.count > maxOptions {
                lines.append(String(format: strings.moreOptions, options.count - maxOptions))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The first non-empty line of a permission detail, with "…" when more
    /// followed. A command's first line says what it does; the rest is
    /// typically a heredoc body — a file's contents, a script, a key — that
    /// has no business on a lock screen or in a group chat.
    static func firstLine(of detail: String?) -> String? {
        guard let detail else { return nil }
        let lines = detail.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        let more = lines[(index + 1)...].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return more ? first + " …" : first
    }

    /// Plain, redacted, bounded text. Keeps line structure (a reply's bullet
    /// list stays readable) and runs every line through the same credential
    /// redaction the notch uses before anything leaves the Mac. `markdown`
    /// drops the syntax a lock screen would show literally — only for prose:
    /// in a command, `**` is a glob and backticks are substitutions.
    public static func clean(_ value: String?, limit: Int, markdown: Bool = false) -> String? {
        guard let value else { return nil }
        var lines: [String] = []
        for rawLine in precut(value, keeping: limit).components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if markdown {
                if line.hasPrefix("```") { continue }
                while line.hasPrefix("#") { line.removeFirst() }
                if line.hasPrefix("> ") { line.removeFirst(2) }
                line = line.replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
            }
            // sanitizedSummary also collapses runs of whitespace; limit is
            // applied once to the whole text below, not per line.
            if let redacted = HookEvent.sanitizedSummary(line, limit: Int.max) {
                lines.append(redacted)
            }
        }
        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return truncated(joined, limit: limit)
    }

    /// A long reply is cut before the redaction pass rather than after it:
    /// running every regex over each line of a 50 KB transcript reply only
    /// to keep 200 characters costs the main thread milliseconds per push.
    /// The cut is loose — redaction and Markdown stripping change lengths —
    /// and lands on a line boundary, or failing that a word boundary, so a
    /// credential is never split into a piece the patterns no longer know.
    static func precut(_ text: String, keeping limit: Int) -> String {
        let budget = max(limit, 1) * 2 + 256
        guard text.utf16.count > budget,
              let end = text.index(text.startIndex, offsetBy: budget, limitedBy: text.endIndex) else {
            return text
        }
        let head = text[..<end]
        if let newline = head.lastIndex(where: \.isNewline), newline > head.startIndex {
            return String(head[..<newline])
        }
        if let space = head.lastIndex(where: \.isWhitespace), space > head.startIndex {
            return String(head[..<space])
        }
        return String(head)
    }

    /// Character-bounded, with an ellipsis so a cut is visible as a cut.
    public static func truncated(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        guard limit > 1 else { return "…" }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// UTF-8 byte bounded (WeCom and ntfy count bytes, and a CJK character is
    /// three of them). Never splits a character.
    public static func truncated(_ text: String, maxUTF8Bytes: Int) -> String {
        guard text.utf8.count > maxUTF8Bytes else { return text }
        let ellipsis = "…"
        let budget = maxUTF8Bytes - ellipsis.utf8.count
        guard budget > 0 else { return "" }
        var used = 0
        var result = ""
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            used += size
            result.append(character)
        }
        return result + ellipsis
    }

    /// UTF-16 code-unit bounded (Telegram counts these). Never splits a
    /// character — a family emoji is eight units and goes whole or not at all.
    public static func truncated(_ text: String, maxUTF16 limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        let budget = limit - 1  // "…" is one unit
        guard budget > 0 else { return "" }
        var used = 0
        var result = ""
        for character in text {
            let size = character.utf16.count
            if used + size > budget { break }
            used += size
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Permission detail

public enum PushDetailSummarizer {
    private static let commandKeys = ["command", "cmd", "CommandLine", "commandLine", "script"]
    private static let pathKeys = [
        "file_path", "filePath", "notebook_path", "AbsolutePath", "TargetFile", "target_file", "path",
    ]
    private static let otherKeys = ["url", "query", "pattern", "description", "prompt"]

    /// The part of a tool call a person needs to judge it remotely: the
    /// command for shells, the path (relative to the project) for file tools,
    /// otherwise the first descriptive field, falling back to the island's own
    /// one-line description.
    public static func permissionDetail(
        toolInput: [String: Any]?,
        fallback: String?,
        cwd: String?
    ) -> String? {
        if let input = toolInput {
            if let command = firstText(in: input, keys: commandKeys) {
                return command
            }
            if let path = firstText(in: input, keys: pathKeys) {
                return displayPath(path, cwd: cwd)
            }
            if let other = firstText(in: input, keys: otherKeys) {
                return other
            }
        }
        guard let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty else { return nil }
        return fallback
    }

    /// Project-relative when inside the session's cwd; home-relative paths
    /// are handled by the redaction pass (`/Users/name` → `~`).
    public static func displayPath(_ path: String, cwd: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return trimmed
        }
        let root = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if trimmed.hasPrefix(root + "/") {
            return String(trimmed.dropFirst(root.count + 1))
        }
        return trimmed
    }

    /// Strings, or string arrays (Codex passes argv as `["bash", "-lc", "…"]`).
    private static func firstText(in input: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = input[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let parts = input[key] as? [String] {
                let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            }
        }
        return nil
    }
}
