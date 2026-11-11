import Foundation

/// Lifecycle of one entry in an agent's own task checklist.
public enum AgentTaskStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed

    /// Outcome of reading a provider's free-form status string.
    enum Parsed: Equatable {
        case status(AgentTaskStatus)
        /// The entry left the list (Claude `deleted`, Gemini/OpenCode `cancelled`).
        case removed
        /// Absent or unrecognised — callers pick a default.
        case unknown
    }

    /// Normalise the status vocabularies of every checklist tool we read:
    /// Claude TaskUpdate / TodoWrite, Codex update_plan, Gemini write_todos and
    /// OpenCode todowrite all say `pending` / `in_progress` / `completed`, but
    /// forks drift on casing and separators.
    static func parse(_ raw: Any?) -> Parsed {
        guard let raw = raw as? String else { return .unknown }
        let key = raw.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "pending", "todo", "not_started", "open", "queued":
            return .status(.pending)
        case "in_progress", "inprogress", "active", "running", "doing", "started":
            return .status(.inProgress)
        case "completed", "complete", "done", "finished":
            return .status(.completed)
        case "deleted", "removed", "cancelled", "canceled":
            return .removed
        default:
            return .unknown
        }
    }

    /// A status this build does not know (written by a newer version and read
    /// back after a downgrade) decodes as `pending` instead of failing the
    /// checklist — and with it the whole persisted session.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if case .status(let status) = Self.parse(raw) {
            self = status
        } else {
            self = .pending
        }
    }
}

/// One row of an agent's checklist as shown on the session card.
public struct AgentTaskItem: Codable, Equatable, Sendable, Identifiable {
    /// Stable row identity. Assigned once and never rewritten, so a TaskCreate
    /// draft that later learns its provider id keeps its SwiftUI identity.
    public let id: String
    /// Provider task id: Claude's `TaskCreate` result, or the row id a
    /// snapshot list carries (Cursor `todo_write` rows have one, so a later
    /// `merge: true` call can address them). nil for rows without one and for
    /// a create whose result is pending.
    public var taskId: String?
    /// tool_use id of the TaskCreate call that introduced the row. It is the
    /// only key shared by the call (PreToolUse / transcript `tool_use`) and its
    /// result, which is where the provider id first appears.
    public var createOpId: String?
    public var title: String
    /// Present-continuous label ("Running tests") shown while in progress.
    public var activeForm: String?
    public var status: AgentTaskStatus

    public init(
        id: String,
        taskId: String? = nil,
        createOpId: String? = nil,
        title: String,
        activeForm: String? = nil,
        status: AgentTaskStatus
    ) {
        self.id = id
        self.taskId = taskId
        self.createOpId = createOpId
        self.title = title
        self.activeForm = activeForm
        self.status = status
    }

    /// What the compact row says while this item is the one being worked on.
    public var progressLabel: String { activeForm ?? title }
}

/// A row of a snapshot-style list (TodoWrite, update_plan, write_todos): the
/// tool re-sends the whole list every time, so rows carry no identity.
public struct AgentTaskDraft: Equatable, Sendable {
    public var title: String
    public var activeForm: String?
    public var status: AgentTaskStatus
    /// The row's own id when the tool sends one (Cursor `todo_write`).
    public var rowId: String?

    public init(title: String, activeForm: String? = nil, status: AgentTaskStatus, rowId: String? = nil) {
        self.title = title
        self.activeForm = activeForm
        self.status = status
        self.rowId = rowId
    }
}

/// One row of a `todo_write` call with `merge: true` (Cursor): only the fields
/// it carries change, on the row with the same id. Cursor's partial updates
/// send just `{id, status}`.
public struct AgentTaskRowPatch: Equatable, Sendable {
    public var rowId: String?
    public var change: AgentTaskChange

    public init(rowId: String?, change: AgentTaskChange) {
        self.rowId = rowId
        self.change = change
    }
}

/// Field changes carried by one Claude `TaskUpdate`.
public struct AgentTaskChange: Equatable, Sendable {
    public var status: AgentTaskStatus?
    public var isDeletion: Bool
    public var title: String?
    public var activeForm: String?

    public init(status: AgentTaskStatus? = nil, isDeletion: Bool = false, title: String? = nil, activeForm: String? = nil) {
        self.status = status
        self.isDeletion = isDeletion
        self.title = title
        self.activeForm = activeForm
    }

    /// Later changes win field by field; a deletion is final.
    func merged(with later: AgentTaskChange) -> AgentTaskChange {
        AgentTaskChange(
            status: later.status ?? status,
            isDeletion: isDeletion || later.isDeletion,
            title: later.title ?? title,
            activeForm: later.activeForm ?? activeForm
        )
    }
}

/// One observation about an agent's checklist, from a hook or a transcript row.
///
/// Hooks and the transcript describe the *same* tool calls, and Claude's
/// PostToolUse hooks run async (they can overtake the next PreToolUse), so
/// every operation carries the provider's tool-call id (`opId`). The list
/// applies each (kind, opId) once, whichever channel delivers it first.
public enum AgentTaskEvent: Equatable, Sendable {
    /// A new user prompt began a turn.
    case newTurn
    /// The agent's turn ended (Stop hook; Codex `task_complete` /
    /// `turn_aborted`). Lets the list notice a whole turn that never touched
    /// a snapshot plan.
    case turnEnded
    /// TaskCreate was called; its provider id is not known yet.
    case create(opId: String, title: String, activeForm: String?)
    /// TaskCreate returned the provider id for the call `opId`.
    case created(opId: String?, taskId: String, title: String?, activeForm: String?)
    /// A transcript result row that only *reads* like a TaskCreate result
    /// ("Task #7 created successfully: …") and carries no structured result.
    /// Result rows do not name their tool and MCP tools can print the same
    /// words, so this only completes the draft the call `opId` created; it
    /// never adds a row of its own.
    case createdPerText(opId: String, taskId: String, title: String?)
    /// TaskUpdate for `taskId`. `expectedFrom` is set when the event comes from
    /// a *result* (`statusChange.from`): an async result that lost the race to
    /// a newer update must not roll the status back.
    case update(opId: String?, taskId: String, change: AgentTaskChange, expectedFrom: AgentTaskStatus?)
    /// The call `opId` failed or was rejected (e.g. a TaskCompleted hook
    /// blocked the completion) — undo whatever it did.
    case opFailed(opId: String)
    /// A full-list snapshot replaced the checklist (TodoWrite / update_plan).
    case replace(opId: String?, items: [AgentTaskDraft])
    /// A partial snapshot merged into the checklist by row id (Cursor
    /// `todo_write` with `merge: true`); rows it doesn't mention stay.
    case merge(opId: String?, rows: [AgentTaskRowPatch])

    /// Whether this event can put rows on a list that starts out empty. A
    /// transcript whose only events are prompts, failures (any failing tool
    /// yields `.opFailed`) or text-only results holds no checklist history,
    /// so replaying it must not replace what hooks or persistence built.
    public var buildsList: Bool {
        switch self {
        case .create, .created, .update, .replace, .merge: return true
        case .newTurn, .turnEnded, .createdPerText, .opFailed: return false
        }
    }

    var isTurnBoundary: Bool {
        switch self {
        case .newTurn, .turnEnded: return true
        default: return false
        }
    }

    /// Dedupe key for this operation, or nil when it is naturally idempotent.
    var dedupeKey: String? {
        switch self {
        case .newTurn, .turnEnded: return nil
        case .create(let opId, _, _): return "c|\(opId)"
        case .created(let opId, _, _, _): return opId.map { "r|\($0)" }
        case .createdPerText(let opId, _, _): return "r|\(opId)"
        case .update(let opId, _, _, _): return opId.map { "u|\($0)" }
        case .opFailed(let opId): return "f|\(opId)"
        case .replace(let opId, _): return opId.map { "w|\($0)" }
        // One call is either a replace or a merge, so they share the key.
        case .merge(let opId, _): return opId.map { "w|\($0)" }
        }
    }
}

/// An agent's own task checklist for one session: TaskCreate/TaskUpdate
/// (Claude Code), TodoWrite (older Claude Code and forks), update_plan
/// (Codex), write_todos / todowrite (Gemini / OpenCode).
///
/// A pure value type: the reducer applies hook events to it and AppState
/// applies transcript events, both through ``apply(_:now:)``. Only `items` and
/// `completedAt` are persisted; the dedupe/undo bookkeeping is rebuilt from the
/// transcript on relaunch.
public struct AgentTaskList: Sendable {
    public private(set) var items: [AgentTaskItem] = []
    /// When every item last became completed; nil while any item is open. The
    /// card keeps a finished list up briefly, then lets it go (see
    /// ``isVisible(now:linger:)``) — no timer involved.
    public private(set) var completedAt: Date?

    // MARK: Transient bookkeeping (not persisted)

    private var appliedOpKeys: [String] = []
    private var appliedOpKeySet: Set<String> = []
    /// Updates for a task whose TaskCreate result has not arrived yet (Claude's
    /// async PostToolUse can land after the next TaskUpdate's PreToolUse).
    private var parkedChanges: [String: ParkedChange] = [:]
    /// What each recent update replaced, so a failed call can be undone.
    private var undoJournal: [String: UndoEntry] = [:]
    private var undoJournalOrder: [String] = []

    // Turn tracking, for retiring a snapshot plan the agent stopped updating.
    // Hooks and the transcript both report turn boundaries, in no guaranteed
    // order relative to each other, so repeats of an open/close are ignored.
    /// Between a `.newTurn` and the matching `.turnEnded`.
    private var turnOpen = false
    private var turnStartedAt: Date?
    /// Whether the list was touched since the current turn began. Starts true
    /// so a restored list isn't retired before a whole turn has been seen.
    private var touchedThisTurn = true
    /// A whole turn went by without touching the list.
    private var sawUntouchedTurn = false
    /// Set while ``rebuilt(fromTranscript:coversWholeTranscript:live:)``
    /// replays one transcript: a single, ordered channel stamped
    /// `.distantPast`, where durations mean nothing.
    private var isReplaying = false

    private struct ParkedChange: Sendable {
        var opId: String?
        var change: AgentTaskChange
    }

    private struct UndoEntry: Sendable {
        let before: AgentTaskItem
        /// nil when the op deleted the row.
        let after: AgentTaskItem?
        let index: Int
    }

    /// Bounds for pathological input; real checklists are a handful of rows.
    static let maxItems = 100
    static let maxAppliedOpKeys = 512
    static let maxParkedChanges = 64
    static let maxUndoEntries = 64
    static let maxTitleLength = 200

    /// How long a fully completed list stays on the card before it fades.
    public static let completedLinger: TimeInterval = 8
    /// A turn shorter than this can't count as "a turn without the plan": the
    /// other channel's late end of the *previous* turn lands right after the
    /// next one starts (Codex runs a queued prompt back to back).
    static let minUntouchedTurnDuration: TimeInterval = 3

    public init() {}

    /// Restore a persisted list (or build a preview).
    public init(items: [AgentTaskItem], completedAt: Date? = nil) {
        self.items = Array(items.prefix(Self.maxItems))
        self.completedAt = completedAt
    }

    // MARK: Derived state

    public var isEmpty: Bool { items.isEmpty }
    public var completedCount: Int { items.lazy.filter { $0.status == .completed }.count }
    public var isAllCompleted: Bool { !items.isEmpty && items.allSatisfy { $0.status == .completed } }
    /// The row being worked on right now (first in-progress one).
    public var current: AgentTaskItem? { items.first { $0.status == .inProgress } }
    /// A whole-list snapshot (TodoWrite, update_plan, write_todos) rather than
    /// Claude's TaskCreate tasks, which live on in the CLI's own task store.
    var isSnapshotList: Bool { !items.isEmpty && items.allSatisfy { $0.id.hasPrefix("step:") } }

    /// When a fully completed list should leave the card; nil while open.
    public func hideDeadline(linger: TimeInterval = AgentTaskList.completedLinger) -> Date? {
        guard isAllCompleted, let completedAt else { return nil }
        return completedAt.addingTimeInterval(linger)
    }

    /// Show the compact row? Open lists always; finished ones only until
    /// ``hideDeadline(linger:)``.
    public func isVisible(now: Date, linger: TimeInterval = AgentTaskList.completedLinger) -> Bool {
        guard !items.isEmpty else { return false }
        guard let deadline = hideDeadline(linger: linger) else { return true }
        return now < deadline
    }

    // MARK: Applying events

    /// Apply events in order. Returns whether the visible list changed.
    @discardableResult
    public mutating func apply(_ events: [AgentTaskEvent], now: Date) -> Bool {
        var changed = false
        for event in events {
            if apply(event, now: now) { changed = true }
        }
        return changed
    }

    /// Apply one event. Returns whether the visible list changed.
    @discardableResult
    public mutating func apply(_ event: AgentTaskEvent, now: Date) -> Bool {
        // Nothing for a text-only result to complete: leave its op key free,
        // so the call's structured result (a hook) still lands if it follows.
        if case let .createdPerText(opId, _, _) = event,
           !items.contains(where: { $0.createOpId == opId }) {
            return false
        }
        if let key = event.dedupeKey {
            guard !appliedOpKeySet.contains(key) else { return false }
            recordApplied(key)
        }

        let before = items
        switch event {
        case .newTurn:
            // A new prompt retires a finished checklist. An unfinished one is
            // normally still the agent's plan and stays — unless it is a
            // snapshot plan that a whole turn went by without updating: Codex
            // leaves plans it abandoned half-done, and nothing else clears them.
            if isAllCompleted || (sawUntouchedTurn && isSnapshotList) {
                items.removeAll()
                parkedChanges.removeAll()
                clearUndoJournal()
            }
            if !turnOpen {
                turnOpen = true
                turnStartedAt = now
                touchedThisTurn = false
                sawUntouchedTurn = false
            }

        case .turnEnded:
            guard turnOpen else { return false }
            turnOpen = false
            let lasted = isReplaying ? .infinity : turnStartedAt.map { now.timeIntervalSince($0) } ?? 0
            if !touchedThisTurn, lasted >= Self.minUntouchedTurnDuration {
                sawUntouchedTurn = true
            }
            return false

        case let .create(opId, title, activeForm):
            applyCreate(opId: opId, title: title, activeForm: activeForm)

        case let .created(opId, taskId, title, activeForm):
            applyCreated(opId: opId, taskId: taskId, title: title, activeForm: activeForm)

        case let .createdPerText(opId, taskId, title):
            applyCreated(opId: opId, taskId: taskId, title: title, activeForm: nil)

        case let .update(opId, taskId, change, expectedFrom):
            applyUpdate(opId: opId, taskId: taskId, change: change, expectedFrom: expectedFrom)

        case let .opFailed(opId):
            applyFailure(opId: opId)

        case let .replace(_, drafts):
            items = drafts.prefix(Self.maxItems).enumerated().map { index, draft in
                AgentTaskItem(
                    id: "step:\(index)",
                    taskId: draft.rowId,
                    title: Self.cleanTitle(draft.title),
                    activeForm: draft.activeForm.map(Self.cleanTitle),
                    status: draft.status
                )
            }
            parkedChanges.removeAll()
            clearUndoJournal()

        case let .merge(_, rows):
            applyMerge(rows)
        }

        let changed = items != before
        // A failing unrelated tool also yields .opFailed; only count what
        // actually concerns the list.
        if !event.isTurnBoundary, event.buildsList || changed {
            touchedThisTurn = true
            sawUntouchedTurn = false
        }
        if isAllCompleted {
            if completedAt == nil { completedAt = now }
        } else {
            completedAt = nil
        }
        return changed
    }

    /// Apply a subagent's or teammate's checklist events to the parent's list.
    ///
    /// They work through the parent's shared Claude task list, so a TaskUpdate
    /// on a task the parent already shows moves that row (and a failed one is
    /// undone). Anything else a child does — its own creates, updates to its
    /// own tasks, snapshot lists — stays off the parent card.
    @discardableResult
    public mutating func applySharedUpdates(_ events: [AgentTaskEvent], now: Date) -> Bool {
        var changed = false
        for event in events {
            let targetsOwnRow: Bool
            switch event {
            case let .update(_, taskId, _, _):
                targetsOwnRow = items.contains { $0.taskId == taskId }
            case let .opFailed(opId):
                targetsOwnRow = undoJournal[opId] != nil
            default:
                targetsOwnRow = false
            }
            if targetsOwnRow, apply(event, now: now) { changed = true }
        }
        return changed
    }

    /// Rebuild a session's list from its transcript on attach.
    ///
    /// - A transcript without checklist-building operations (see
    ///   ``AgentTaskEvent/buildsList``) says nothing new: keep `live`.
    /// - A scan that covered the whole transcript is authoritative: replay it
    ///   from empty (persisted rows are the same tool calls, replayed).
    /// - A scan of only the transcript's tail cannot see creates older than the
    ///   window, so it replays on top of the live rows instead; per-id merges
    ///   keep that idempotent.
    ///
    /// Replayed completions are stamped `.distantPast`: a list that finished
    /// before CodeIsland attached must not flash "all done" on the card.
    public static func rebuilt(
        fromTranscript events: [AgentTaskEvent],
        coversWholeTranscript: Bool,
        live: AgentTaskList
    ) -> AgentTaskList {
        guard events.contains(where: \.buildsList) else { return live }
        var board = coversWholeTranscript
            ? AgentTaskList()
            : AgentTaskList(items: live.items, completedAt: live.completedAt)
        board.isReplaying = true
        board.apply(events, now: .distantPast)
        board.isReplaying = false
        return board
    }

    // MARK: - Operation handlers

    private mutating func applyCreate(opId: String, title: String, activeForm: String?) {
        let title = Self.cleanTitle(title)
        let activeForm = activeForm.map(Self.cleanTitle)
        if let index = items.firstIndex(where: { $0.createOpId == opId }) {
            // Result already landed via the other channel — just fill gaps.
            if items[index].activeForm == nil { items[index].activeForm = activeForm }
            if items[index].title.isEmpty { items[index].title = title }
            return
        }
        guard items.count < Self.maxItems else { return }
        items.append(AgentTaskItem(
            id: "op:\(opId)",
            createOpId: opId,
            title: title,
            activeForm: activeForm,
            status: .pending
        ))
    }

    private mutating func applyCreated(opId: String?, taskId: String, title: String?, activeForm: String?) {
        let title = title.map(Self.cleanTitle).flatMap { $0.isEmpty ? nil : $0 }
        let activeForm = activeForm.map(Self.cleanTitle)
        var index = items.firstIndex { $0.taskId == taskId }
        if let opId, let draft = items.firstIndex(where: { $0.createOpId == opId && $0.taskId == nil }) {
            if index == nil {
                items[draft].taskId = taskId
                index = draft
            } else {
                // Both a draft and an id-keyed row exist for one create; keep
                // the id-keyed row.
                items.remove(at: draft)
                index = items.firstIndex { $0.taskId == taskId }
            }
        }
        if index == nil {
            guard items.count < Self.maxItems else { return }
            items.append(AgentTaskItem(
                id: "task:\(taskId)",
                taskId: taskId,
                createOpId: opId,
                title: title ?? "#\(taskId)",
                activeForm: activeForm,
                status: .pending
            ))
            index = items.count - 1
        }
        guard let index else { return }
        if items[index].createOpId == nil { items[index].createOpId = opId }
        if let title, items[index].title.isEmpty || items[index].title == "#\(taskId)" {
            items[index].title = title
        }
        if items[index].activeForm == nil { items[index].activeForm = activeForm }
        if let parked = parkedChanges.removeValue(forKey: taskId) {
            applyChange(parked.change, opId: parked.opId, at: index)
        }
    }

    private mutating func applyUpdate(
        opId: String?,
        taskId: String,
        change: AgentTaskChange,
        expectedFrom: AgentTaskStatus?
    ) {
        guard let index = items.firstIndex(where: { $0.taskId == taskId }) else {
            // The TaskCreate result is still in flight — park the change until
            // the row exists.
            if let existing = parkedChanges[taskId] {
                parkedChanges[taskId] = ParkedChange(opId: opId ?? existing.opId, change: existing.change.merged(with: change))
            } else if parkedChanges.count < Self.maxParkedChanges {
                parkedChanges[taskId] = ParkedChange(opId: opId, change: change)
            }
            return
        }
        // A result whose transition no longer matches lost the race to a newer
        // update; replaying it would roll the status back.
        if let expectedFrom, change.status != nil || change.isDeletion,
           items[index].status != expectedFrom {
            return
        }
        applyChange(change, opId: opId, at: index)
    }

    private mutating func applyChange(_ change: AgentTaskChange, opId: String?, at index: Int) {
        let before = items[index]
        if change.isDeletion {
            items.remove(at: index)
            if let opId { journal(opId, UndoEntry(before: before, after: nil, index: index)) }
            return
        }
        if let status = change.status { items[index].status = status }
        if let title = change.title.map(Self.cleanTitle), !title.isEmpty { items[index].title = title }
        if let activeForm = change.activeForm.map(Self.cleanTitle) { items[index].activeForm = activeForm }
        if let opId, items[index] != before {
            journal(opId, UndoEntry(before: before, after: items[index], index: index))
        }
    }

    private mutating func applyMerge(_ rows: [AgentTaskRowPatch]) {
        for row in rows {
            if let rowId = row.rowId, let index = items.firstIndex(where: { $0.taskId == rowId }) {
                applyChange(row.change, opId: nil, at: index)
                continue
            }
            // A row the list doesn't have yet needs at least a title; an
            // `{id, status}` patch for a row we never saw has nothing to show.
            guard !row.change.isDeletion,
                  let title = row.change.title.map(Self.cleanTitle), !title.isEmpty,
                  items.count < Self.maxItems else { continue }
            var slot = items.count
            while items.contains(where: { $0.id == "step:\(slot)" }) { slot += 1 }
            items.append(AgentTaskItem(
                id: "step:\(slot)",
                taskId: row.rowId,
                title: title,
                activeForm: row.change.activeForm.map(Self.cleanTitle),
                status: row.change.status ?? .pending
            ))
        }
    }

    private mutating func applyFailure(opId: String) {
        if let entry = undoJournal.removeValue(forKey: opId) {
            undoJournalOrder.removeAll { $0 == opId }
            if let after = entry.after {
                // Only undo while the row still shows this op's result — a
                // newer update since then must not be rolled back with it.
                if let index = items.firstIndex(where: { $0.id == after.id }), items[index] == after {
                    items[index] = entry.before
                }
            } else if !items.contains(where: { $0.id == entry.before.id }) {
                items.insert(entry.before, at: min(entry.index, items.count))
            }
            return
        }
        if let draft = items.firstIndex(where: { $0.createOpId == opId && $0.taskId == nil }) {
            // TaskCreate itself failed: the draft never became a task.
            items.remove(at: draft)
            return
        }
        if let parked = parkedChanges.first(where: { $0.value.opId == opId })?.key {
            parkedChanges.removeValue(forKey: parked)
        }
    }

    // MARK: - Bookkeeping

    private mutating func recordApplied(_ key: String) {
        appliedOpKeys.append(key)
        appliedOpKeySet.insert(key)
        let overflow = appliedOpKeys.count - Self.maxAppliedOpKeys
        if overflow > 0 {
            for evicted in appliedOpKeys.prefix(overflow) { appliedOpKeySet.remove(evicted) }
            appliedOpKeys.removeFirst(overflow)
        }
    }

    private mutating func journal(_ opId: String, _ entry: UndoEntry) {
        if undoJournal.updateValue(entry, forKey: opId) == nil {
            undoJournalOrder.append(opId)
        }
        let overflow = undoJournalOrder.count - Self.maxUndoEntries
        if overflow > 0 {
            for evicted in undoJournalOrder.prefix(overflow) { undoJournal.removeValue(forKey: evicted) }
            undoJournalOrder.removeFirst(overflow)
        }
    }

    private mutating func clearUndoJournal() {
        undoJournal.removeAll()
        undoJournalOrder.removeAll()
    }

    /// Collapse whitespace/newlines to one line and bound the length — titles
    /// come straight from model output.
    static func cleanTitle(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxTitleLength else { return collapsed }
        return String(collapsed.prefix(maxTitleLength - 1)) + "…"
    }
}

extension AgentTaskList: Equatable {
    /// Visible state only; bookkeeping differences do not matter to callers.
    public static func == (lhs: AgentTaskList, rhs: AgentTaskList) -> Bool {
        lhs.items == rhs.items && lhs.completedAt == rhs.completedAt
    }
}

extension AgentTaskList: Codable {
    private enum CodingKeys: String, CodingKey {
        case items
        case completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try container.decodeIfPresent([AgentTaskItem].self, forKey: .items) ?? [],
            completedAt: try container.decodeIfPresent(Date.self, forKey: .completedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}
