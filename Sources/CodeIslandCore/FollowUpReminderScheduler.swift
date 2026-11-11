import Foundation

/// What a follow-up reminder is about.
public enum FollowUpReminderKind: String, Sendable, CaseIterable {
    /// A permission request still waiting for allow / deny.
    case approval
    /// A question (AskUserQuestion, Notification question, Codex
    /// request_user_input) still waiting for an answer.
    case question
    /// A finished turn the user has not looked at yet.
    case completion

    /// Approvals and questions block the agent, so they are worth nagging
    /// about a few times; a finished turn blocks nothing and gets one nudge.
    public var maxAttempts: Int {
        switch self {
        case .approval, .question: return 3
        case .completion: return 1
        }
    }
}

/// One follow-up reminder, handed to whoever reacts to it (the island's sound
/// and card, and any push channel wired to `FollowUpReminderController`).
public struct FollowUpReminder: Equatable, Sendable {
    /// Where the waiting item lives, and so what a reminder can do about it.
    public enum Origin: String, Equatable, Sendable {
        /// The island holds it: a queued approval / question, or a finished
        /// turn. Its card can be shown again.
        case island
        /// A display-only wait: it exists only as the session's waiting status
        /// (Claude Desktop Cowork, Cursor's in-IDE question, AiWork, a
        /// terminal permission prompt announced by a Notification hook). It
        /// can only be answered in the app that asked, so a reminder chimes
        /// and hints but has no card to open.
        case displayOnly
    }

    public enum Delivery: String, Equatable, Sendable {
        /// Delivered locally at its due time.
        case onTime
        /// Came due while local reminders were held back (screen locked,
        /// screen saver, quiet hours). Nothing played on the
        /// Mac; a `.catchUp` follows if the item is still waiting when the hold
        /// ends. Remote channels may still want this one — the user is away.
        case deferred
        /// The held-back reminder, delivered as soon as the hold ended.
        case catchUp
    }

    public let kind: FollowUpReminderKind
    public let sessionId: String
    /// 1-based. For `.deferred` it is the attempt that is owed.
    public let attempt: Int
    public let maxAttempts: Int
    /// When the item started waiting (request arrival / turn completion).
    public let waitingSince: Date
    public let delivery: Delivery
    public let origin: Origin
    /// The queued request this reminder is about, when the island holds one
    /// (see `FollowUpReminderScheduler.sync(kind:requests:now:)`); nil for
    /// display-only waits and finished turns.
    public let requestId: String?
    /// An `.onTime` reminder the island kept to itself because the user
    /// seemed to be in front of the item (its card under the pointer, the
    /// session's terminal tab in front). Nothing played on the Mac. Remote
    /// channels still get it: "the terminal is in front" only means someone
    /// is looking while someone is at the Mac, and a Mac left unlocked keeps
    /// reporting its last frontmost app.
    public let locallySuppressed: Bool
    /// A `.completion` whose turn ended on an error (StopFailure, a failed
    /// AiWork stream, a failed Cowork turn): the Mac rings the error sound
    /// again, and no channel may present it as work that finished.
    public let turnFailed: Bool

    public init(
        kind: FollowUpReminderKind,
        sessionId: String,
        attempt: Int,
        maxAttempts: Int,
        waitingSince: Date,
        delivery: Delivery,
        origin: Origin = .island,
        requestId: String? = nil,
        locallySuppressed: Bool = false,
        turnFailed: Bool = false
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.waitingSince = waitingSince
        self.delivery = delivery
        self.origin = origin
        self.requestId = requestId
        self.locallySuppressed = locallySuppressed
        self.turnFailed = turnFailed
    }

    /// The same reminder, marked as kept off the Mac (`locallySuppressed`).
    public func suppressedLocally() -> FollowUpReminder {
        FollowUpReminder(
            kind: kind, sessionId: sessionId, attempt: attempt, maxAttempts: maxAttempts,
            waitingSince: waitingSince, delivery: delivery, origin: origin, requestId: requestId,
            locallySuppressed: true, turnFailed: turnFailed
        )
    }

    /// No further reminder will follow for this item.
    public var isFinal: Bool { delivery != .deferred && attempt >= maxAttempts }
}

/// Pure timing state machine behind follow-up reminders. No timers, no clock:
/// every mutation takes `now`, and the owner arms a single wake-up for
/// `nextWakeDate` — so with the feature off (or nothing waiting) there is no
/// state and nothing scheduled.
///
/// Items come in two flavours:
/// - **Synced** (approvals, questions): the owner reports the full set of
///   sessions that are waiting via `sync`, and entries appear and disappear
///   with it. A silenced or exhausted entry stays until its item stops
///   waiting, so a later sync cannot restart the reminders for the very same
///   request. There is one entry per session, and when the island names the
///   request a session waits on, the entry belongs to that request: the
///   session's next request starts over instead of inheriting the previous
///   one's attempts or silence. Each synced entry has an origin — held by the
///   island, or a display-only wait read off the session's status — and each
///   origin is reconciled on its own (see `sync(kind:origin:waiting:now:)`).
/// - **Tracked** (completions): started by an event with `track`; a newer
///   event for the same session restarts it, and it is dropped once done.
///
/// A reminder the owner decides not to deliver after all — the user turned
/// out to be looking at the item — is handed back with `postpone`: nothing
/// was spent, and it comes due again an interval later.
///
/// Holding back (lock screen, quiet hours) does not pause the clock: an item
/// that comes due while held is marked owed, and the first tick after the hold
/// delivers it at once as a catch-up. Missed attempts collapse into that one
/// catch-up rather than being spent silently.
public struct FollowUpReminderScheduler: Sendable {
    public struct Key: Hashable, Sendable {
        public let kind: FollowUpReminderKind
        public let sessionId: String

        public init(_ kind: FollowUpReminderKind, _ sessionId: String) {
            self.kind = kind
            self.sessionId = sessionId
        }
    }

    struct Entry: Sendable {
        var waitingSince: Date
        /// Last delivery, or `waitingSince` before the first one. Due times
        /// are anchored here so changing the interval re-times everything.
        var anchor: Date
        var delivered: Int
        /// Came due while held back; waiting for the hold to end.
        var owed: Bool
        /// Out of attempts, or silenced by the owner. Kept (synced entries
        /// only) so the same waiting item is not re-tracked from scratch.
        var done: Bool
        /// Created by `sync` rather than `track`.
        var synced: Bool
        var origin: FollowUpReminder.Origin = .island
        /// The island's request this entry reminds about; nil when the wait
        /// has no request of its own (display-only, tracked).
        var requestId: String?
        /// Tracked completions only: the turn ended on an error.
        var turnFailed = false
    }

    /// Seconds between reminders; nil means the feature is off.
    public private(set) var interval: TimeInterval?
    private var entries: [Key: Entry] = [:]

    public init(interval: TimeInterval? = nil) {
        self.interval = Self.normalized(interval)
    }

    public var isEnabled: Bool { interval != nil }
    public var isEmpty: Bool { entries.isEmpty }
    public var trackedKeys: Set<Key> { Set(entries.keys) }
    public var hasOwed: Bool { entries.values.contains { $0.owed && !$0.done } }

    /// Items that can still produce a reminder.
    public var liveKeys: Set<Key> { Set(entries.filter { !$0.value.done }.keys) }

    /// Turning the feature off drops everything; changing the interval
    /// re-times pending entries from their last delivery.
    public mutating func setInterval(_ newValue: TimeInterval?) {
        interval = Self.normalized(newValue)
        if interval == nil { entries.removeAll() }
    }

    /// Reconcile one synced kind against the sessions whose request the
    /// island holds, without naming the requests.
    public mutating func sync(kind: FollowUpReminderKind, waiting: Set<String>, now: Date) {
        sync(kind: kind, origin: .island, waiting: waiting, now: now)
    }

    /// Reconcile one synced kind against the island's queue: `requests` maps
    /// each waiting session to the request its card shows. A session whose
    /// request changed — the one it was reminded about was answered and the
    /// next one took its place without the session ever leaving the queue —
    /// is a new wait: fresh timing, no attempts spent, not silenced.
    public mutating func sync(kind: FollowUpReminderKind, requests: [String: String], now: Date) {
        reconcile(kind: kind, origin: .island, waiting: requests.mapValues { Optional($0) }, now: now)
    }

    /// Reconcile the entries of one kind and origin against the sessions
    /// currently waiting that way. Entries of the other origin are left
    /// alone: the island's queues are re-read on every change, display-only
    /// waits only once a session's status has settled — a queue that empties
    /// a beat before its session's status catches up must not read as a
    /// display-only wait.
    ///
    /// A listed session that already has an entry of the other origin is the
    /// same wait changing hands (a terminal permission prompt the island then
    /// queued): the entry is adopted with its timing, attempts and silence.
    public mutating func sync(
        kind: FollowUpReminderKind,
        origin: FollowUpReminder.Origin,
        waiting: Set<String>,
        now: Date
    ) {
        reconcile(
            kind: kind,
            origin: origin,
            waiting: Dictionary(uniqueKeysWithValues: waiting.map { ($0, String?.none) }),
            now: now
        )
    }

    private mutating func reconcile(
        kind: FollowUpReminderKind,
        origin: FollowUpReminder.Origin,
        waiting: [String: String?],
        now: Date
    ) {
        guard isEnabled else { return }
        for (key, entry) in entries
        where key.kind == kind && entry.origin == origin && waiting[key.sessionId] == nil {
            entries.removeValue(forKey: key)
        }
        for (sessionId, requestId) in waiting {
            let key = Key(kind, sessionId)
            if let entry = entries[key],
               !Self.isNewRequest(requestId, replacing: entry.requestId) {
                entries[key]?.origin = origin
                if let requestId { entries[key]?.requestId = requestId }
            } else {
                entries[key] = Entry(
                    waitingSince: now, anchor: now, delivered: 0, owed: false, done: false,
                    synced: true, origin: origin, requestId: requestId
                )
            }
        }
    }

    /// Two named requests that differ are two waits. A wait without a name
    /// (display-only) handing over to a named one — or back — is the same
    /// wait changing hands.
    private static func isNewRequest(_ requestId: String?, replacing current: String?) -> Bool {
        guard let requestId, let current else { return false }
        return requestId != current
    }

    /// A new wait began for a synced item that may still be tracked from an
    /// earlier one whose end was never seen (the session left the wait and
    /// came back between two syncs). Start it over: fresh timing, no attempts
    /// spent, not silenced.
    public mutating func restart(
        kind: FollowUpReminderKind,
        sessionId: String,
        origin: FollowUpReminder.Origin,
        now: Date
    ) {
        guard isEnabled else { return }
        entries[Key(kind, sessionId)] = Entry(
            waitingSince: now, anchor: now, delivered: 0, owed: false, done: false,
            synced: true, origin: origin
        )
    }

    /// Where a tracked item is waiting; nil when it is not tracked.
    public func origin(of key: Key) -> FollowUpReminder.Origin? {
        entries[key]?.origin
    }

    /// Start (or restart) an event-driven item. `turnFailed`: a completion
    /// whose turn ended on an error; its reminders say so.
    public mutating func track(kind: FollowUpReminderKind, sessionId: String, now: Date, turnFailed: Bool = false) {
        guard isEnabled else { return }
        entries[Key(kind, sessionId)] = Entry(
            waitingSince: now, anchor: now, delivered: 0, owed: false, done: false, synced: false,
            turnFailed: turnFailed
        )
    }

    /// Hand back a reminder `collectDue` just produced that reached nobody:
    /// the user was already looking at the item. The attempt is not spent
    /// and the item is not silenced — being in front of it once says nothing
    /// about the next time — it simply comes due again an interval from
    /// `now`. Ignored when the entry has since moved on to another wait
    /// (answered, restarted, a newer request) or been silenced.
    public mutating func postpone(_ reminder: FollowUpReminder, now: Date) {
        guard isEnabled else { return }
        let key = Key(reminder.kind, reminder.sessionId)
        guard var entry = entries[key],
              entry.waitingSince == reminder.waitingSince,
              entry.requestId == reminder.requestId,
              entry.delivered == reminder.attempt else { return }
        entry.delivered = reminder.attempt - 1
        entry.owed = false
        entry.done = false
        entry.anchor = now
        entries[key] = entry
    }

    /// Stop reminding about an item (seen, jumped to, handled elsewhere).
    public mutating func silence(_ key: Key) {
        guard let entry = entries[key] else { return }
        if entry.synced {
            entries[key]?.done = true
            entries[key]?.owed = false
        } else {
            entries.removeValue(forKey: key)
        }
    }

    public mutating func silenceAll(sessionId: String) {
        for key in entries.keys where key.sessionId == sessionId {
            silence(key)
        }
    }

    public mutating func silenceAll(kind: FollowUpReminderKind) {
        for key in entries.keys where key.kind == kind {
            silence(key)
        }
    }

    public mutating func reset() {
        entries.removeAll()
    }

    /// Earliest moment a live, not-yet-owed entry comes due. Owed entries are
    /// waiting on the hold to end, not on the clock.
    public func nextWakeDate() -> Date? {
        guard let interval else { return nil }
        return entries.values
            .filter { !$0.done && !$0.owed }
            .map { $0.anchor.addingTimeInterval(interval) }
            .min()
    }

    /// Advance to `now`. While `heldBack`, due items become owed (reported
    /// once as `.deferred`); otherwise due and owed items are delivered and
    /// counted. Results are ordered approvals → questions → completions, then
    /// oldest first, so the caller can pick "the most urgent" from the head.
    public mutating func collectDue(now: Date, heldBack: Bool) -> [FollowUpReminder] {
        guard let interval else { return [] }
        // A tracked item's last reminder is kept until the next pass, so the
        // owner can still postpone it; nothing else reads a done entry.
        entries = entries.filter { $0.value.synced || !$0.value.done }
        var out: [FollowUpReminder] = []
        for (key, entry) in entries where !entry.done {
            let isDue = now >= entry.anchor.addingTimeInterval(interval)
            guard entry.owed || isDue else { continue }
            let attempt = entry.delivered + 1
            let maxAttempts = key.kind.maxAttempts
            if heldBack {
                guard !entry.owed else { continue }  // already reported
                entries[key]?.owed = true
                out.append(FollowUpReminder(
                    kind: key.kind, sessionId: key.sessionId, attempt: attempt,
                    maxAttempts: maxAttempts, waitingSince: entry.waitingSince, delivery: .deferred,
                    origin: entry.origin, requestId: entry.requestId, turnFailed: entry.turnFailed
                ))
                continue
            }
            out.append(FollowUpReminder(
                kind: key.kind, sessionId: key.sessionId, attempt: attempt,
                maxAttempts: maxAttempts, waitingSince: entry.waitingSince,
                delivery: entry.owed ? .catchUp : .onTime, origin: entry.origin,
                requestId: entry.requestId, turnFailed: entry.turnFailed
            ))
            if attempt >= maxAttempts {
                entries[key]?.done = true
                entries[key]?.owed = false
                entries[key]?.delivered = attempt
            } else {
                entries[key]?.delivered = attempt
                entries[key]?.owed = false
                entries[key]?.anchor = now
            }
        }
        return out.sorted(by: Self.urgency)
    }

    private static func urgency(_ a: FollowUpReminder, _ b: FollowUpReminder) -> Bool {
        let order: [FollowUpReminderKind] = [.approval, .question, .completion]
        let ra = order.firstIndex(of: a.kind) ?? 0
        let rb = order.firstIndex(of: b.kind) ?? 0
        if ra != rb { return ra < rb }
        if a.waitingSince != b.waitingSince { return a.waitingSince < b.waitingSince }
        return a.sessionId < b.sessionId
    }

    private static func normalized(_ interval: TimeInterval?) -> TimeInterval? {
        guard let interval, interval > 0 else { return nil }
        return interval
    }
}
