import Foundation
import Darwin

/// A checklist tool an agent can call. Names are matched case- and
/// separator-insensitively because forks re-spell them (`todo_write`,
/// `write_todos`, `todowrite`).
enum AgentTaskTool: Equatable {
    /// Claude Code ≥ 2.1 `TaskCreate {subject, description, activeForm}`.
    case taskCreate
    /// Claude Code ≥ 2.1 `TaskUpdate {taskId, status, subject?, activeForm?}`.
    case taskUpdate
    /// Whole-list todo writers: Claude `TodoWrite`, Gemini `write_todos`,
    /// OpenCode `todowrite`, Qwen `todo_write` — `{todos: [...]}`.
    case todoSnapshot
    /// Codex `update_plan {explanation?, plan: [{step, status}]}`.
    case planSnapshot

    init?(toolName: String?) {
        guard let toolName,
              let tool = Self.byNormalizedName[Self.normalizedName(toolName)] else { return nil }
        self = tool
    }

    /// Lowercased, separators dropped: `todo_write` / `TodoWrite` → `todowrite`.
    static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }

    static let byNormalizedName: [String: AgentTaskTool] = [
        "taskcreate": .taskCreate,
        "taskupdate": .taskUpdate,
        "todowrite": .todoSnapshot,
        "writetodos": .todoSnapshot,
        "updateplan": .planSnapshot,
    ]

    /// Events implied by a *call* of this tool (its input alone).
    func callEvents(opId: String?, input: [String: Any]) -> [AgentTaskEvent] {
        switch self {
        case .taskCreate:
            guard let opId,
                  let subject = AgentTaskParsing.string(input, ["subject", "title", "content"]) else { return [] }
            return [.create(
                opId: opId,
                title: subject,
                activeForm: AgentTaskParsing.string(input, ["activeForm", "active_form"])
            )]
        case .taskUpdate:
            guard let taskId = AgentTaskParsing.idString(input["taskId"] ?? input["task_id"] ?? input["id"]) else {
                return []
            }
            let change = AgentTaskParsing.change(fromUpdateInput: input)
            guard change != AgentTaskChange() else { return [] }
            return [.update(opId: opId, taskId: taskId, change: change, expectedFrom: nil)]
        case .todoSnapshot:
            // Cursor's todo_write can send only the rows that changed.
            if AgentTaskParsing.flag(input["merge"]) {
                guard let rows = AgentTaskParsing.rowPatches(from: input["todos"]) else { return [] }
                return [.merge(opId: opId, rows: rows)]
            }
            guard let drafts = AgentTaskParsing.drafts(from: input["todos"]) else { return [] }
            return [.replace(opId: opId, items: drafts)]
        case .planSnapshot:
            guard let drafts = AgentTaskParsing.drafts(from: input["plan"]) else { return [] }
            return [.replace(opId: opId, items: drafts)]
        }
    }

    /// Events implied by a successful *result* of this tool (hook
    /// `tool_response`). Snapshot tools repeat their call — same op key, so
    /// the list applies it once.
    func resultEvents(opId: String?, input: [String: Any], response: Any?) -> [AgentTaskEvent] {
        switch self {
        case .taskCreate:
            let dict = AgentTaskParsing.jsonObject(response)
            let task = dict?["task"] as? [String: Any]
            let taskId = AgentTaskParsing.idString(task?["id"])
                ?? AgentTaskParsing.createdTaskId(fromResultText: response as? String)
            guard let taskId else { return [] }
            return [.created(
                opId: opId,
                taskId: taskId,
                title: (task?["subject"] as? String) ?? AgentTaskParsing.string(input, ["subject", "title", "content"]),
                activeForm: AgentTaskParsing.string(input, ["activeForm", "active_form"])
            )]
        case .taskUpdate:
            let dict = AgentTaskParsing.jsonObject(response) ?? [:]
            if dict["success"] as? Bool == false {
                // e.g. a TaskCompleted hook blocked the completion.
                return opId.map { [.opFailed(opId: $0)] } ?? []
            }
            guard let taskId = AgentTaskParsing.idString(input["taskId"] ?? input["task_id"] ?? dict["taskId"]) else {
                return []
            }
            var change = AgentTaskParsing.change(fromUpdateInput: input)
            let statusChange = dict["statusChange"] as? [String: Any]
            if change.status == nil, !change.isDeletion, let to = statusChange?["to"] {
                switch AgentTaskStatus.parse(to) {
                case .status(let status): change.status = status
                case .removed: change.isDeletion = true
                case .unknown: break
                }
            }
            guard change != AgentTaskChange() else { return [] }
            var expectedFrom: AgentTaskStatus?
            if case .status(let from) = AgentTaskStatus.parse(statusChange?["from"]) {
                expectedFrom = from
            }
            return [.update(opId: opId, taskId: taskId, change: change, expectedFrom: expectedFrom)]
        case .todoSnapshot, .planSnapshot:
            return callEvents(opId: opId, input: input)
        }
    }
}

enum AgentTaskParsing {
    static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Task ids are strings on the wire ("1"), but tolerate numbers.
    static func idString(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber, !(value is Bool) {
            return number.stringValue
        }
        return nil
    }

    /// Tool arguments arrive as an object from hooks but as a JSON *string*
    /// in Codex rollouts (`function_call.arguments`).
    static func jsonObject(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let string = value as? String,
              string.first == "{",
              let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func change(fromUpdateInput input: [String: Any]) -> AgentTaskChange {
        var change = AgentTaskChange()
        switch AgentTaskStatus.parse(input["status"]) {
        case .status(let status): change.status = status
        case .removed: change.isDeletion = true
        case .unknown: break
        }
        change.title = string(input, ["subject", "title"])
        change.activeForm = string(input, ["activeForm", "active_form"])
        return change
    }

    /// A boolean argument, tolerating `"true"` / `1` from loosely typed callers.
    static func flag(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return string.lowercased() == "true" }
        return false
    }

    private static let rowTitleKeys = ["content", "subject", "step", "title", "description", "text", "task"]

    /// The rows of a list argument, which arrives as an array from hooks and
    /// as a JSON string from Codex rollouts. nil when it is not a list.
    private static func rowObjects(from value: Any?) -> [[String: Any]]? {
        let array: [Any]
        if let list = value as? [Any] {
            array = list
        } else if let string = value as? String,
                  string.first == "[",
                  let data = string.data(using: .utf8),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            array = list
        } else {
            return nil
        }
        return array.compactMap { $0 as? [String: Any] }
    }

    /// Rows of a whole-list snapshot. nil when `value` is not a list at all
    /// (malformed call); an empty array is a real "list cleared".
    static func drafts(from value: Any?) -> [AgentTaskDraft]? {
        rowObjects(from: value)?.compactMap { row in
            guard let title = string(row, rowTitleKeys) else { return nil }
            let status: AgentTaskStatus
            switch AgentTaskStatus.parse(row["status"]) {
            case .status(let parsed): status = parsed
            case .removed: return nil
            case .unknown: status = .pending
            }
            return AgentTaskDraft(
                title: title,
                activeForm: string(row, ["activeForm", "active_form"]),
                status: status,
                rowId: idString(row["id"])
            )
        }
    }

    /// Rows of a `merge: true` list update. Unlike a snapshot row, any field
    /// may be missing — `{id, status}` is the common case.
    static func rowPatches(from value: Any?) -> [AgentTaskRowPatch]? {
        rowObjects(from: value)?.compactMap { row in
            var change = AgentTaskChange()
            switch AgentTaskStatus.parse(row["status"]) {
            case .status(let status): change.status = status
            case .removed: change.isDeletion = true
            case .unknown: break
            }
            change.title = string(row, rowTitleKeys)
            change.activeForm = string(row, ["activeForm", "active_form"])
            let rowId = idString(row["id"])
            guard rowId != nil || change.title != nil, change != AgentTaskChange() else { return nil }
            return AgentTaskRowPatch(rowId: rowId, change: change)
        }
    }

    /// Claude's text result for TaskCreate: "Task #7 created successfully: …".
    static func createdTaskId(fromResultText text: String?) -> String? {
        guard let text,
              let hash = text.range(of: "Task #"),
              let end = text.range(of: " created successfully", range: hash.upperBound..<text.endIndex) else {
            return nil
        }
        let id = text[hash.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return id.isEmpty || id.contains(" ") ? nil : id
    }

    static func resultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return blocks.lazy.compactMap { $0["text"] as? String }.first
    }
}

// MARK: - Hooks

/// Checklist events carried by one hook event.
public enum AgentTaskHookParser {
    /// `normalizedEventName` is `EventNormalizer.normalize(event.eventName)`.
    /// Callers must route subagent (`agent_id`) events elsewhere first — a
    /// child's own checklist does not belong on the parent card.
    public static func events(from event: HookEvent, normalizedEventName: String) -> [AgentTaskEvent] {
        switch normalizedEventName {
        case "UserPromptSubmit":
            return [.newTurn]
        case "Stop", "Interrupt", "TaskRoundComplete":
            return [.turnEnded]
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            break
        default:
            return []
        }
        guard let tool = AgentTaskTool(toolName: event.toolName) else { return [] }
        let opId = event.toolUseId
        let input = event.toolInput
            ?? AgentTaskParsing.jsonObject(event.rawJSON["tool_input"] ?? event.rawJSON["arguments"])
            ?? [:]
        switch normalizedEventName {
        case "PreToolUse":
            return tool.callEvents(opId: opId, input: input)
        case "PostToolUse":
            return tool.resultEvents(
                opId: opId,
                input: input,
                response: event.rawJSON["tool_response"] ?? event.rawJSON["toolResponse"]
            )
        default:
            // Failed or denied: whatever the PreToolUse applied never happened.
            return opId.map { [.opFailed(opId: $0)] } ?? []
        }
    }
}

// MARK: - Transcripts

/// Checklist events carried by transcript rows: Claude Code JSONL (and the
/// Claude-format forks) plus Codex rollouts.
public enum AgentTaskTranscript {
    /// Events carried by one decoded transcript row.
    public static func events(fromLine json: [String: Any]) -> [AgentTaskEvent] {
        // Older Claude builds interleave subagent rows into the parent
        // transcript; a child's checklist never belongs on the parent card.
        if json["isSidechain"] as? Bool == true { return [] }
        switch json["type"] as? String {
        case "assistant": return claudeAssistantEvents(json)
        case "user": return claudeUserEvents(json)
        case "response_item": return codexResponseItemEvents(json)
        case "event_msg": return codexEventMsgEvents(json)
        default: return []
        }
    }

    private static func claudeAssistantEvents(_ json: [String: Any]) -> [AgentTaskEvent] {
        let message = (json["message"] as? [String: Any]) ?? json
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var events: [AgentTaskEvent] = []
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let tool = AgentTaskTool(toolName: block["name"] as? String) else { continue }
            let input = AgentTaskParsing.jsonObject(block["input"]) ?? [:]
            events.append(contentsOf: tool.callEvents(opId: block["id"] as? String, input: input))
        }
        return events
    }

    private static func claudeUserEvents(_ json: [String: Any]) -> [AgentTaskEvent] {
        if json["isMeta"] as? Bool == true { return [] }
        // The compaction summary is written as a user row but starts no turn.
        let startsTurn = json["isCompactSummary"] as? Bool != true
        let message = (json["message"] as? [String: Any]) ?? json
        let content = message["content"]

        if let text = content as? String {
            // A local slash command (/model, /effort) and its output are user
            // rows too, but no turn.
            let isPrompt = startsTurn
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && JSONLTailer.claudeCommandEcho(text) != .local
            return isPrompt ? [.newTurn] : []
        }
        guard let blocks = content as? [[String: Any]] else { return [] }

        var events: [AgentTaskEvent] = []
        if startsTurn, blocks.contains(where: {
            $0["type"] as? String == "text"
                && !(($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            events.append(.newTurn)
        }
        let results = blocks.filter { $0["type"] as? String == "tool_result" }
        // `toolUseResult` is the structured result of the row's tool call; it
        // is only unambiguous when the row answers exactly one call.
        let structured = results.count == 1 ? json["toolUseResult"] as? [String: Any] : nil
        for block in results {
            guard let opId = block["tool_use_id"] as? String else { continue }
            if block["is_error"] as? Bool == true {
                events.append(.opFailed(opId: opId))
                continue
            }
            events.append(contentsOf: claudeResultEvents(opId: opId, structured: structured, content: block["content"]))
        }
        return events
    }

    /// The result row does not name its tool, so recognise it by shape.
    private static func claudeResultEvents(opId: String, structured: [String: Any]?, content: Any?) -> [AgentTaskEvent] {
        if let structured {
            // TaskCreate → {task: {id, subject}}. TaskGet returns the same key
            // *with* a status; a read changes nothing, so skip it.
            if let task = structured["task"] as? [String: Any], task["status"] == nil,
               let taskId = AgentTaskParsing.idString(task["id"]) {
                return [.created(opId: opId, taskId: taskId, title: task["subject"] as? String, activeForm: nil)]
            }
            // TaskUpdate → {success, taskId, updatedFields, statusChange?}.
            if let success = structured["success"] as? Bool,
               let taskId = AgentTaskParsing.idString(structured["taskId"]),
               structured["updatedFields"] != nil {
                guard success else { return [.opFailed(opId: opId)] }
                guard let statusChange = structured["statusChange"] as? [String: Any] else { return [] }
                var change = AgentTaskChange()
                switch AgentTaskStatus.parse(statusChange["to"]) {
                case .status(let status): change.status = status
                case .removed: change.isDeletion = true
                case .unknown: return []
                }
                var expectedFrom: AgentTaskStatus?
                if case .status(let from) = AgentTaskStatus.parse(statusChange["from"]) {
                    expectedFrom = from
                }
                return [.update(opId: opId, taskId: taskId, change: change, expectedFrom: expectedFrom)]
            }
            return []
        }
        // Rows answering several calls at once carry no usable toolUseResult;
        // TaskCreate's text result still names the new id. Any other tool (an
        // MCP server's, say) may print the same words, so the list only lets
        // this complete a TaskCreate draft — never add a row.
        guard let text = AgentTaskParsing.resultText(content),
              let taskId = AgentTaskParsing.createdTaskId(fromResultText: text) else { return [] }
        let title = text.range(of: "created successfully:").map {
            text[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return [.createdPerText(opId: opId, taskId: taskId, title: title)]
    }

    private static func codexResponseItemEvents(_ json: [String: Any]) -> [AgentTaskEvent] {
        guard let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "function_call",
              let tool = AgentTaskTool(toolName: payload["name"] as? String) else { return [] }
        let input = AgentTaskParsing.jsonObject(payload["arguments"]) ?? [:]
        return tool.callEvents(opId: payload["call_id"] as? String, input: input)
    }

    private static func codexEventMsgEvents(_ json: [String: Any]) -> [AgentTaskEvent] {
        guard let payload = json["payload"] as? [String: Any] else { return [] }
        switch payload["type"] as? String {
        case "task_started", "user_message": return [.newTurn]
        case "task_complete", "turn_aborted", "turn_failed": return [.turnEnded]
        default: return []
        }
    }

    // MARK: Attach-time backfill

    /// Result of scanning a transcript for checklist history.
    public struct Backfill: Equatable, Sendable {
        public let events: [AgentTaskEvent]
        /// False when only the tail window was read (older rows unseen).
        public let coversWholeFile: Bool
    }

    /// Read checklist events from the transcript bytes before `endOffset`
    /// (the size captured when the live tailer attached, so the two never
    /// overlap). Only the last `maxBytes` are read, and rows larger than
    /// `maxLineBytes` — giant tool results, never checklist calls — are
    /// skipped unparsed. Blocking file I/O: call off the main actor.
    public static func scanFile(
        atPath path: String,
        endOffset: UInt64,
        maxBytes: UInt64 = 8 * 1024 * 1024,
        maxLineBytes: Int = 256 * 1024
    ) -> Backfill? {
        guard endOffset > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let start = endOffset > maxBytes ? endOffset - maxBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(endOffset - start)) else { return nil }
        return Backfill(
            events: scan(data, startsAtLineBoundary: start == 0, maxLineBytes: maxLineBytes),
            coversWholeFile: start == 0
        )
    }

    /// Checklist events in a JSONL blob, in order. A leading partial row
    /// (window cut mid-line) and a trailing unterminated row are ignored.
    public static func scan(_ data: Data, startsAtLineBoundary: Bool, maxLineBytes: Int = 256 * 1024) -> [AgentTaskEvent] {
        var events: [AgentTaskEvent] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let total = raw.count
            var lineStart = 0
            var skipFirst = !startsAtLineBoundary
            while lineStart < total {
                guard let newline = memchr(base + lineStart, 0x0A, total - lineStart) else { break }
                let lineEnd = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(newline))
                defer { lineStart = lineEnd + 1 }
                if skipFirst {
                    skipFirst = false
                    continue
                }
                let length = lineEnd - lineStart
                guard length > 0, length <= maxLineBytes,
                      mayCarryTaskEvent(base + lineStart, length: length) else { continue }
                let lineData = Data(bytes: base + lineStart, count: length)
                guard let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
                events.append(contentsOf: self.events(fromLine: json))
            }
        }
        return events
    }

    /// Byte prefilter so the backfill decodes only rows that can matter. It
    /// must pass every row the live parser acts on: a row it drops here is
    /// missing from the replay that rebuilds the list from empty.
    static func mayCarryTaskEvent(_ ptr: UnsafePointer<UInt8>, length: Int) -> Bool {
        if namesChecklistTool(ptr, length: length) { return true }
        for marker in operationMarkers where contains(ptr, length: length, marker: marker) {
            return true
        }
        // A Claude prompt row: a user row that answers no tool call.
        return contains(ptr, length: length, marker: claudeUserTypeMarker)
            && !contains(ptr, length: length, marker: toolUseIdMarker)
    }

    /// Whether any `"name":"…"` value in the row is a checklist tool, spelled
    /// any way `AgentTaskTool(toolName:)` accepts (`TodoWrite`, `todo_write`,
    /// `write_todos`, `todowrite`, …).
    private static func namesChecklistTool(_ ptr: UnsafePointer<UInt8>, length: Int) -> Bool {
        let maxNameBytes = 32
        var offset = 0
        while offset < length {
            let found = nameMarker.withUnsafeBytes { needle in
                memmem(ptr + offset, length - offset, needle.baseAddress, needle.count)
            }
            guard let found else { return false }
            let valueStart = UnsafeRawPointer(ptr).distance(to: UnsafeRawPointer(found)) + nameMarker.count
            var normalized: [UInt8] = []
            var index = valueStart
            while index < length, index - valueStart < maxNameBytes, ptr[index] != 0x22 {  // '"'
                let byte = ptr[index]
                switch byte {
                case 0x5F, 0x2D, 0x20: break  // '_', '-', ' '
                case 0x41...0x5A: normalized.append(byte + 0x20)  // A-Z → a-z
                default: normalized.append(byte)
                }
                index += 1
            }
            if index < length, ptr[index] == 0x22, checklistToolNames.contains(normalized) {
                return true
            }
            offset = valueStart
        }
        return false
    }

    private static let nameMarker = Array(#""name":""#.utf8)
    private static let checklistToolNames = Set(AgentTaskTool.byNormalizedName.keys.map { Array($0.utf8) })

    /// Key-order independent: TaskCreate results say "created successfully" in
    /// their text, TaskUpdate results always carry `updatedFields`.
    private static let operationMarkers: [[UInt8]] = [
        #" created successfully"#,
        #""updatedFields":"#,
        #""is_error":true"#,
        #""type":"task_started""#,
        #""type":"user_message""#,
        #""type":"task_complete""#,
        #""type":"turn_aborted""#,
        #""type":"turn_failed""#,
    ].map { Array($0.utf8) }
    private static let claudeUserTypeMarker = Array(#""type":"user""#.utf8)
    private static let toolUseIdMarker = Array(#""tool_use_id""#.utf8)

    private static func contains(_ ptr: UnsafePointer<UInt8>, length: Int, marker: [UInt8]) -> Bool {
        marker.withUnsafeBytes { needle in
            memmem(ptr, length, needle.baseAddress, needle.count) != nil
        }
    }
}
