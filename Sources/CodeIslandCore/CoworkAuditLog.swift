import Foundation

/// One `audit.jsonl` line, reduced to what moves a Cowork card.
///
/// Claude Desktop appends every SDK message of the in-VM CLI to the audit log
/// (all `stream_event` deltas excluded), plus its own permission-card records:
///
///     {"type":"user", …}                                  prompt, or a tool_result
///     {"type":"system","subtype":"init", …}               a turn's CLI (re)start
///     {"type":"assistant", …, "parent_tool_use_id":null}  model output (main agent)
///     {"type":"system","subtype":"permission_request","uuid":…,"tool_name":…,"tool_input":…}
///     {"type":"system","subtype":"permission_response","uuid":…,"decision":…,"granted":…}
///     {"type":"result","subtype":"success","is_error":false,"result":…}   turn over
///     {"type":"result","subtype":"error_during_execution","is_error":true,
///      "terminal_reason":"aborted_streaming",…}           the user pressed Stop
public enum CoworkAuditEvent: Equatable, Sendable {
    /// A new turn from the user (or a synthetic meta-notification Claude
    /// Desktop injects into the input stream).
    case userPrompt(text: String?, isSynthetic: Bool)
    /// A tool finished; the turn is still running.
    case toolResult
    /// Model output. `isSubagent` when it belongs to a Task subagent
    /// (`parent_tool_use_id` set) — those run beside a main agent that may
    /// still be blocked on a permission card. `toolUse` when the output is a
    /// tool call (the CLI streams each content block as its own line).
    case assistantOutput(isSubagent: Bool, toolUse: ToolUse?)
    /// The CLI (re)started for a turn — also the only marker of a turn Claude
    /// Desktop resumes on its own, without a user line.
    case turnActivity
    case permissionRequested(id: String?, toolName: String, detail: String?)
    case permissionResolved(id: String?)
    /// `interrupted` when the user stopped the turn in Claude Desktop. The
    /// CLI reports that as an error result (`error_during_execution`) whose
    /// `terminal_reason` says it was aborted; it is not a failure, and
    /// `isError` is then false.
    case turnEnded(isError: Bool, resultText: String?, interrupted: Bool = false)
    case ignored

    public struct ToolUse: Equatable, Sendable {
        public let name: String
        public let detail: String?

        public init(name: String, detail: String?) {
            self.name = name
            self.detail = detail
        }
    }
}

public enum CoworkAuditParser {
    /// Lines above this are never handed to JSONSerialization. Tool results and
    /// assistant messages can run to megabytes; everything we need from those
    /// comes from byte markers instead.
    static let maxParsedLineBytes = 512 * 1024

    public static func event(fromLine line: Data) -> CoworkAuditEvent {
        guard let type = topLevelType(line) else { return .ignored }
        switch type {
        case "assistant":
            // Quotes inside JSON string values are always escaped, so these
            // markers can only match real keys, never quoted content — text and
            // thinking lines skip the parser entirely.
            let isSubagent = line.range(of: parentToolUseNullMarker) == nil
            guard line.range(of: toolUseMarker) != nil,
                  let json = parse(line),
                  let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]],
                  let block = content.last(where: { $0["type"] as? String == "tool_use" }),
                  let name = trimmed(block["name"]) else {
                return .assistantOutput(isSubagent: isSubagent, toolUse: nil)
            }
            return .assistantOutput(
                isSubagent: isSubagent,
                toolUse: CoworkAuditEvent.ToolUse(name: name, detail: toolDetail(toolName: name, input: block["input"]))
            )
        case "user":
            if line.range(of: toolUseIdMarker) != nil || line.range(of: toolResultMarker) != nil {
                return .toolResult
            }
            guard let json = parse(line) else { return .userPrompt(text: nil, isSynthetic: false) }
            let message = json["message"] as? [String: Any]
            return .userPrompt(
                text: promptText(message?["content"]),
                isSynthetic: (json["isSynthetic"] as? Bool) == true
            )
        case "result":
            guard let json = parse(line) else {
                let interrupted = line.range(of: abortedTerminalReasonMarker) != nil
                return .turnEnded(
                    isError: !interrupted && line.range(of: isErrorTrueMarker) != nil,
                    resultText: nil,
                    interrupted: interrupted
                )
            }
            let interrupted = (json["terminal_reason"] as? String)?.hasPrefix(abortedTerminalReasonPrefix) ?? false
            let subtype = json["subtype"] as? String
            let isError = !interrupted
                && ((json["is_error"] as? Bool) == true || (subtype?.hasPrefix("error") ?? false))
            return .turnEnded(isError: isError, resultText: trimmed(json["result"]), interrupted: interrupted)
        case "system":
            // `init` carries the full tool/skill inventory — tens of KB per turn
            // that only need recognising, not parsing.
            if line.starts(with: systemInitPrefix) { return .turnActivity }
            guard let json = parse(line) else { return .ignored }
            switch json["subtype"] as? String {
            case "init":
                return .turnActivity
            case "permission_request":
                let tool = trimmed(json["tool_name"]) ?? "tool"
                return .permissionRequested(
                    id: trimmed(json["uuid"]),
                    toolName: tool,
                    detail: toolDetail(toolName: tool, input: json["tool_input"])
                )
            case "permission_response":
                return .permissionResolved(id: trimmed(json["uuid"]))
            default:
                // permission_auto_approved / _denied, compact boundaries, status
                // pings: none of them change whether the turn is running.
                return .ignored
            }
        default:
            return .ignored
        }
    }

    /// Split a byte blob on newlines. Bytes after the last newline come back as
    /// the fragment to prepend to the next read (a line still being written).
    public static func events(in data: Data) -> (events: [CoworkAuditEvent], trailingFragment: Data) {
        var events: [CoworkAuditEvent] = []
        var lineStart = data.startIndex
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if data[cursor] == 0x0A {
                if cursor > lineStart {
                    events.append(event(fromLine: Data(data[lineStart..<cursor])))
                }
                lineStart = data.index(after: cursor)
            }
            cursor = data.index(after: cursor)
        }
        return (events, Data(data[lineStart..<data.endIndex]))
    }

    // MARK: - Helpers

    private static let typePrefix = Data(#"{"type":""#.utf8)
    private static let systemInitPrefix = Data(#"{"type":"system","subtype":"init""#.utf8)
    private static let parentToolUseNullMarker = Data(#""parent_tool_use_id":null"#.utf8)
    private static let toolUseIdMarker = Data(#""tool_use_id":""#.utf8)
    private static let toolResultMarker = Data(#""type":"tool_result""#.utf8)
    private static let toolUseMarker = Data(#""type":"tool_use""#.utf8)
    private static let isErrorTrueMarker = Data(#""is_error":true"#.utf8)
    /// The CLI's own "was this turn aborted" test (shared by the Claude Code
    /// build Claude Desktop runs and by Claude Desktop itself) is
    /// `aborted_streaming` or `aborted_tools` — stopped mid-reply or while a
    /// tool ran. Matched by prefix so a new abort flavour still reads as one.
    private static let abortedTerminalReasonPrefix = "aborted_"
    private static let abortedTerminalReasonMarker = Data(#""terminal_reason":"aborted_"#.utf8)

    /// Every audit record is written as `{"type":"…",…}` — SDK messages lead with
    /// `type`, and Claude Desktop's own records are object literals with `type`
    /// first. Reading the value straight off the prefix keeps megabyte-sized
    /// tool results out of the JSON parser; anything else falls back to a parse.
    static func topLevelType(_ line: Data) -> String? {
        if line.starts(with: typePrefix) {
            let valueStart = line.startIndex + typePrefix.count
            let searchEnd = min(line.endIndex, valueStart + 64)
            if let quote = line[valueStart..<searchEnd].firstIndex(of: 0x22) {
                return String(data: line[valueStart..<quote], encoding: .utf8)
            }
        }
        return parse(line)?["type"] as? String
    }

    private static func parse(_ line: Data) -> [String: Any]? {
        guard line.count <= maxParsedLineBytes else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let result = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func promptText(_ content: Any?) -> String? {
        if let string = content as? String { return trimmed(string) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return trimmed(block["text"])
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// One-line context for a tool call or permission card: the command, path
    /// or URL at stake; for AskUserQuestion, the question itself.
    static func toolDetail(toolName: String, input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        if toolName == "AskUserQuestion" {
            let questions = (input["questions"] as? [[String: Any]])?
                .compactMap { trimmed($0["question"]) } ?? []
            guard let first = questions.first else { return trimmed(input["question"]).map { clip($0) } }
            return clip(questions.count > 1 ? "\(first) (+\(questions.count - 1))" : first)
        }
        for key in ["command", "file_path", "path", "url", "pattern", "query", "description"] {
            if let value = trimmed(input[key]) { return clip(hostReadablePaths(value)) }
        }
        return nil
    }

    /// The VM sees a granted folder at `/sessions/<vm-name>/mnt/<folder>/…`.
    /// Drop the sandbox prefix so the card reads `<folder>/…` like the user's
    /// own tree instead of an opaque VM path.
    static func hostReadablePaths(_ text: String) -> String {
        guard text.contains("/sessions/") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return vmMountPrefix.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static let vmMountPrefix = try! NSRegularExpression(pattern: "/sessions/[A-Za-z0-9_-]+/mnt/")

    private static func clip(_ text: String, max: Int = 160) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > max ? String(singleLine.prefix(max)) + "…" : singleLine
    }
}

/// Turn state of one Cowork session, folded from its audit events.
public struct CoworkAuditState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case processing
        /// A permission card is up in Claude Desktop.
        case waitingApproval
        /// Claude asked an AskUserQuestion in Claude Desktop.
        case waitingQuestion
    }

    public struct PendingPermission: Equatable, Sendable {
        public let id: String?
        public let toolName: String
        public let detail: String?
    }

    public private(set) var phase: Phase = .idle
    /// Oldest first. Parallel tool calls can hold several cards at once.
    public private(set) var pendingPermissions: [PendingPermission] = []
    public private(set) var promptCount = 0
    public private(set) var completedTurnCount = 0
    public private(set) var permissionRequestCount = 0
    public private(set) var lastPrompt: String?
    /// The final assistant text the `result` record carried, if any.
    public private(set) var lastResultText: String?
    public private(set) var lastTurnFailed = false
    /// The last turn was stopped by the user rather than finished or failed.
    public private(set) var lastTurnInterrupted = false
    /// The tool call currently in flight (latest `tool_use` seen), cleared
    /// when the model goes back to writing text or the turn ends.
    public private(set) var currentTool: CoworkAuditEvent.ToolUse?

    public init() {}

    /// The card the island describes — the newest one, which is also the one
    /// Claude Desktop shows on top.
    public var activePermission: PendingPermission? { pendingPermissions.last }

    public mutating func apply(_ event: CoworkAuditEvent) {
        switch event {
        case .userPrompt(let text, let isSynthetic):
            phase = .processing
            pendingPermissions.removeAll()
            currentTool = nil
            promptCount += 1
            lastResultText = nil
            lastTurnFailed = false
            lastTurnInterrupted = false
            if !isSynthetic, let text { lastPrompt = text }

        case .toolResult, .turnActivity:
            // Neither says anything about a pending card: a parallel tool can
            // finish while its sibling still waits for approval.
            if phase == .idle { phase = .processing }

        case .assistantOutput(let isSubagent, let toolUse):
            // The main agent only speaks again once every tool of its previous
            // step resolved, so no card of that step can still be pending. That
            // also clears requests Claude Desktop superseded or aborted without
            // logging a response. A subagent's output proves nothing.
            if !isSubagent { pendingPermissions.removeAll() }
            if let toolUse {
                currentTool = toolUse
            } else if !isSubagent {
                currentTool = nil
            }
            refreshPhase(defaultPhase: .processing)

        case .permissionRequested(let id, let toolName, let detail):
            if let id { pendingPermissions.removeAll { $0.id == id } }
            pendingPermissions.append(PendingPermission(id: id, toolName: toolName, detail: detail))
            permissionRequestCount += 1
            refreshPhase(defaultPhase: .processing)

        case .permissionResolved(let id):
            if let index = pendingPermissions.firstIndex(where: { id != nil && $0.id == id }) {
                pendingPermissions.remove(at: index)
            } else if !pendingPermissions.isEmpty {
                pendingPermissions.removeFirst()
            }
            refreshPhase(defaultPhase: .processing)

        case .turnEnded(let isError, let resultText, let interrupted):
            phase = .idle
            pendingPermissions.removeAll()
            currentTool = nil
            completedTurnCount += 1
            lastTurnFailed = isError && !interrupted
            lastTurnInterrupted = interrupted
            lastResultText = resultText

        case .ignored:
            break
        }
    }

    public mutating func apply(_ events: [CoworkAuditEvent]) {
        for event in events { apply(event) }
    }

    private mutating func refreshPhase(defaultPhase: Phase) {
        if let active = pendingPermissions.last {
            phase = active.toolName == "AskUserQuestion" ? .waitingQuestion : .waitingApproval
        } else {
            phase = defaultPhase
        }
    }
}
