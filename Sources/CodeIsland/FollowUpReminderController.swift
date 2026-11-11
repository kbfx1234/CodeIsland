import AppKit
import SwiftUI
import Observation
import CodeIslandCore

extension Notification.Name {
    /// Posted by `TerminalActivator` when the user jumps to a session's
    /// terminal. `userInfo["sessionId"]` carries the island session id.
    static let codeIslandDidJumpToSession = Notification.Name("CodeIslandDidJumpToSession")
}

/// Follow-up reminders: approvals and questions still waiting, and finished
/// turns nobody looked at, get another nudge after the configured interval.
///
/// Timing lives in the pure `FollowUpReminderScheduler`; this controller feeds
/// it from `AppState` (queues, display-only waits, completions, surface,
/// jumps), arms at most one wake-up, and turns due reminders into the island's
/// own reactions — the matching sound, the card re-opened when the island is
/// folded away, or a collapsed-state hint when auto-expand is off. A
/// display-only wait (Claude Desktop Cowork, Cursor's in-IDE question, AiWork…)
/// has no card to open: it only chimes and hints. With the setting off it
/// holds no entries and arms nothing.
///
/// Other channels (push to a phone) subscribe with `addReminderHandler`; they
/// receive every reminder, including `.deferred` ones that came due while the
/// Mac itself was held back (locked, screen saver, quiet hours) — exactly when
/// a remote nudge is most useful — and `locallySuppressed` ones the island
/// kept quiet because the user seemed to be in front of the item.
@MainActor
@Observable
final class FollowUpReminderController {
    typealias Key = FollowUpReminderScheduler.Key

    /// Settings values offered in the picker, in minutes; 0 = off.
    static let intervalChoices = [0, 1, 2, 3, 5]

    @ObservationIgnored weak var appState: AppState?
    @ObservationIgnored private(set) var scheduler = FollowUpReminderScheduler()

    /// Reminders delivered while the island was collapsed and could not (or
    /// may not) open their card. Drives the collapsed-state hint.
    private(set) var hintedKeys: Set<Key> = []
    /// Bumped on every hinted delivery so the hint re-animates.
    private(set) var hintPulse = 0

    // MARK: Injection points (tests replace these)

    @ObservationIgnored var clock: () -> Date = Date.init
    @ObservationIgnored var intervalProvider: () -> TimeInterval? = FollowUpReminderController.storedInterval
    /// Quiet hours or nobody at the screen: reminders wait and catch up later.
    @ObservationIgnored var isHeldBack: () -> Bool = { SoundManager.shared.isEventSoundDeferred }
    /// Set by `PanelWindowController`: is the pointer inside the panel's
    /// window at all? The window is a fixed transparent canvas far larger
    /// than the island, so this alone says little; it only guards against a
    /// `pointerOverIsland` left stale by a view that went away mid-hover.
    @ObservationIgnored var isPointerOverPanel: () -> Bool = { false }
    /// Set by the island view's own hover tracking: the pointer is on the
    /// visible island (collapsed bar or expanded card), not merely somewhere
    /// in its window.
    @ObservationIgnored var pointerOverIsland = false
    @ObservationIgnored var terminalFrontmost: (SessionSnapshot) -> Bool =
        TerminalVisibilityDetector.isTerminalFrontmostForSession
    /// Tab-level check; may block on AppleScript, so it always runs detached.
    @ObservationIgnored var tabVisible: @Sendable (SessionSnapshot) -> Bool = { session in
        TerminalVisibilityDetector.isSessionTabVisible(session)
    }
    @ObservationIgnored var playSound: (String) -> Void = { SoundManager.shared.playReminder($0) }
    /// Tests drive `tick(now:)` by hand and turn the real timer off.
    @ObservationIgnored var armsTimer = true

    /// When the single wake-up is due, nil when nothing is scheduled.
    @ObservationIgnored private(set) var armedWakeDate: Date?
    @ObservationIgnored nonisolated(unsafe) private var wakeTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var handlers: [(FollowUpReminder) -> Void] = []
    /// Filled by `remoteChannelDelivered` while `offerSuppressed` runs.
    @ObservationIgnored private var remoteDeliveries: Set<Key> = []
    @ObservationIgnored private var tickInFlight = false
    @ObservationIgnored private var tickRequested = false

    init(appState: AppState) {
        self.appState = appState
        jumpObserver = NotificationCenter.default.addObserver(
            forName: .codeIslandDidJumpToSession, object: nil, queue: .main
        ) { [weak self] note in
            guard let sessionId = note.userInfo?["sessionId"] as? String else { return }
            MainActor.assumeIsolated { self?.userJumped(to: sessionId) }
        }
    }

    deinit {
        wakeTask?.cancel()
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
    }

    /// The stored setting as an interval; nil when off.
    nonisolated static func storedInterval() -> TimeInterval? {
        interval(forMinutes: UserDefaults.standard.integer(forKey: SettingsKey.followUpReminderMinutes))
    }

    nonisolated static func interval(forMinutes minutes: Int) -> TimeInterval? {
        minutes > 0 ? TimeInterval(minutes) * 60 : nil
    }

    // MARK: - Subscribers

    /// Every reminder is handed to every handler, on the main actor, before
    /// the island reacts to it. Shape: see `FollowUpReminder` — including
    /// the `locallySuppressed` ones the island itself keeps quiet about.
    func addReminderHandler(_ handler: @escaping (FollowUpReminder) -> Void) {
        handlers.append(handler)
    }

    /// A handler delivered a `locallySuppressed` reminder somewhere else (a
    /// push to a phone). It reached the user after all, so it counts as an
    /// attempt instead of being postponed — the phone gets at most as many
    /// reminders as the island would have given.
    func remoteChannelDelivered(_ reminder: FollowUpReminder) {
        guard reminder.locallySuppressed else { return }
        remoteDeliveries.insert(Key(reminder.kind, reminder.sessionId))
    }

    // MARK: - Inputs from AppState

    /// The reminder interval changed in Settings.
    func settingsChanged() {
        guard applyInterval() else {
            disarm()
            return
        }
        let now = clock()
        syncWaiting(now: now)
        reschedule(now: now)
    }

    /// Permission / question queues or dismissals changed. Display-only waits
    /// are not re-read here: this runs synchronously inside every queue
    /// mutation, where a session whose request was just answered can still
    /// show its waiting status for a moment.
    func waitingChanged() {
        guard applyInterval() else { return }
        let now = clock()
        syncQueues(now: now)
        reschedule(now: now)
    }

    /// A session's display-only wait began, changed kind or ended (see
    /// AppState+DisplayOnlyWaits). `began` is a wait that just started: its
    /// reminders start over even if an earlier wait's entry was never seen to
    /// end, and a hint left by that earlier wait goes out.
    func displayOnlyWaitsChanged(began: Key? = nil) {
        guard applyInterval() else { return }
        let now = clock()
        syncDisplayOnly(now: now)
        if let began {
            hintedKeys.remove(began)
            scheduler.restart(kind: began.kind, sessionId: began.sessionId, origin: .displayOnly, now: now)
        }
        reschedule(now: now)
    }

    /// A turn finished and was announced, and `AttentionPolicy` decided it is
    /// worth a follow-up (an interrupted turn, the user's own Esc, never is).
    /// A turn that ended on an error is followed up as one (the error sound).
    func trackCompletion(sessionId: String, turnFailed: Bool = false) {
        guard applyInterval() else { return }
        let now = clock()
        scheduler.track(kind: .completion, sessionId: sessionId, now: now, turnFailed: turnFailed)
        reschedule(now: now)
    }

    /// The island's surface changed. Opening the session list shows every
    /// session — pending cards inline, finished turns included — so it counts
    /// as having seen all of it; an approval / question card counts for its
    /// own item.
    func surfaceChanged(_ surface: IslandSurface) {
        guard !scheduler.isEmpty || !hintedKeys.isEmpty else { return }
        switch surface {
        case .sessionList:
            hintedKeys.removeAll()
            scheduler.silenceAll(kind: .completion)
            reschedule(now: clock())
        case .approvalCard(let sid):
            hintedKeys.remove(Key(.approval, sid))
        case .questionCard(let sid):
            hintedKeys.remove(Key(.question, sid))
        case .completionCard, .collapsed:
            break
        }
    }

    /// The pointer entered the completion card: that turn has been seen.
    func completionSeen(sessionId: String) {
        let key = Key(.completion, sessionId)
        hintedKeys.remove(key)
        guard scheduler.trackedKeys.contains(key) else { return }
        scheduler.silence(key)
        reschedule(now: clock())
    }

    /// The user jumped to this session's terminal: they are dealing with it.
    func userJumped(to sessionId: String) {
        hintedKeys = hintedKeys.filter { $0.sessionId != sessionId }
        guard scheduler.trackedKeys.contains(where: { $0.sessionId == sessionId }) else { return }
        scheduler.silenceAll(sessionId: sessionId)
        reschedule(now: clock())
    }

    /// A hold (lock screen, screen saver) just ended: deliver
    /// whatever came due in the meantime right away.
    func wake() {
        guard !scheduler.isEmpty else { return }
        Task { @MainActor [weak self] in await self?.tick() }
    }

    // MARK: - Collapsed-state hint

    /// Lit while a hinted item is still waiting and the user has not opened
    /// the island since. Evaluated on read, so an item answered in the
    /// terminal turns the hint off without any bookkeeping.
    var hintActive: Bool {
        guard !hintedKeys.isEmpty else { return false }
        return hintedKeys.contains { isStillPending($0) }
    }

    // MARK: - Tick

    /// Deliver whatever is due at `now`. The wake-up timer calls this; tests
    /// call it directly with an injected clock.
    func tick(now explicitNow: Date? = nil) async {
        guard applyInterval(), appState != nil else { return }
        if tickInFlight {
            tickRequested = true
            return
        }
        tickInFlight = true
        defer { tickInFlight = false }

        let now = explicitNow ?? clock()
        // Refresh the synced kinds first so a request resolved a moment ago
        // can never fire.
        syncWaiting(now: now)
        let due = scheduler.collectDue(now: now, heldBack: isHeldBack())

        var delivered: [FollowUpReminder] = []
        for reminder in due {
            let key = Key(reminder.kind, reminder.sessionId)
            guard isStillPending(reminder) else {
                scheduler.silence(key)
                continue
            }
            if reminder.delivery == .deferred {
                notify(reminder)
                continue
            }
            // A catch-up skips the "is the user looking" checks: the hold it
            // waited out proves nobody was, whatever app is still in front.
            if reminder.delivery == .onTime {
                var inFront = isBeingLookedAt(key)
                if !inFront {
                    inFront = await isSessionInFront(sessionId: reminder.sessionId)
                }
                // State may have moved while the tab check was off-actor. An
                // entry the sync has since handed to the session's next
                // request is that request's now: leave it alone.
                guard isStillPending(reminder) else { continue }
                if inFront {
                    // The user is in front of it right now: nothing plays on
                    // the Mac. A remote channel may still take it (the Mac
                    // may be unattended with the terminal left in front);
                    // otherwise it reached nobody and costs nothing, and
                    // comes back an interval later. Being in front once is
                    // no answer — only jumping to the session silences it.
                    if !offerSuppressed(reminder) {
                        scheduler.postpone(reminder, now: now)
                    }
                    continue
                }
            }
            delivered.append(reminder)
        }
        perform(delivered)
        reschedule(now: explicitNow ?? clock())

        if tickRequested {
            tickRequested = false
            Task { @MainActor [weak self] in await self?.tick() }
        }
    }

    // MARK: - Private

    /// Re-reads the setting; returns whether reminders are on. Turning them
    /// off drops every entry, hint and wake-up.
    @discardableResult
    private func applyInterval() -> Bool {
        let interval = intervalProvider()
        if scheduler.interval != interval {
            scheduler.setInterval(interval)
            if interval == nil {
                hintedKeys.removeAll()
                disarm()
            }
        }
        return scheduler.isEnabled
    }

    /// Both origins; only from a settled state (tick, settings).
    private func syncWaiting(now: Date) {
        syncQueues(now: now)
        syncDisplayOnly(now: now)
    }

    /// Keyed by the request each card shows, so a session's next request is
    /// reminded about from scratch rather than inheriting the attempts or the
    /// silence of the one before it.
    private func syncQueues(now: Date) {
        guard let appState else { return }
        scheduler.sync(kind: .approval, requests: appState.visiblePermissionRequestIds, now: now)
        scheduler.sync(kind: .question, requests: appState.pendingQuestionRequestIds, now: now)
    }

    private func syncDisplayOnly(now: Date) {
        guard let appState else { return }
        for kind in [FollowUpReminderKind.approval, .question] {
            scheduler.sync(
                kind: kind,
                origin: .displayOnly,
                waiting: appState.displayOnlyWaitingSessionIds(kind: kind),
                now: now
            )
        }
    }

    /// Still waiting, and — for a request the island holds — still the
    /// same request the reminder was about.
    private func isStillPending(_ reminder: FollowUpReminder) -> Bool {
        guard let appState, let requestId = reminder.requestId else {
            return isStillPending(Key(reminder.kind, reminder.sessionId))
        }
        switch reminder.kind {
        case .approval:
            return appState.visiblePermissionRequestIds[reminder.sessionId] == requestId
        case .question:
            return appState.pendingQuestionRequestIds[reminder.sessionId] == requestId
        case .completion:
            return isStillPending(Key(reminder.kind, reminder.sessionId))
        }
    }

    private func isStillPending(_ key: Key) -> Bool {
        guard let appState else { return false }
        switch key.kind {
        case .approval:
            return appState.visiblePermissionSessionIds.contains(key.sessionId)
                || appState.displayOnlyWaitKind(forSession: key.sessionId) == .approval
        case .question:
            return appState.pendingQuestion(forSession: key.sessionId) != nil
                || appState.displayOnlyWaitKind(forSession: key.sessionId) == .question
        case .completion:
            // Any new activity takes the session out of idle; a new finished
            // turn re-tracks it from scratch.
            return appState.sessions[key.sessionId]?.status == .idle
        }
    }

    /// The panel is open on this very item and the pointer is on it. An
    /// auto-opened card nobody is in front of does not count — that is the
    /// user who most needs the reminder.
    private func isBeingLookedAt(_ key: Key) -> Bool {
        guard let appState, pointerOverIsland, isPointerOverPanel() else { return false }
        switch appState.surface {
        case .sessionList:
            return true
        case .approvalCard(let sid):
            return key.kind == .approval && sid == key.sessionId
        case .questionCard(let sid):
            return key.kind == .question && sid == key.sessionId
        case .completionCard(let sid):
            return key.kind == .completion && sid == key.sessionId
        case .collapsed:
            return false
        }
    }

    /// Smart Suppress's question: is this session's own terminal tab in
    /// front? Same setting, same detectors — app level first, tab level only
    /// when the app is frontmost.
    private func isSessionInFront(sessionId: String) async -> Bool {
        guard let appState, let session = appState.sessions[sessionId] else { return false }
        if appState.shouldAutoOpenPendingSurface(for: sessionId, isTerminalFrontmost: terminalFrontmost) {
            return false
        }
        let probe = tabVisible
        return await Task.detached(priority: .userInitiated) { probe(session) }.value
    }

    private func perform(_ reminders: [FollowUpReminder]) {
        guard !reminders.isEmpty, let appState else { return }
        for reminder in reminders { notify(reminder) }

        // One card at a time: the most urgent item gets its card back when the
        // island is folded away; the rest light the hint. A display-only wait
        // has no card on the island — it can only be answered where it was
        // asked — so it always hints.
        var reopened: Key?
        if appState.surface == .collapsed,
           let head = reminders.first(where: { $0.kind != .completion && $0.origin == .island }),
           reopenCard(for: head) {
            reopened = Key(head.kind, head.sessionId)
        }
        var hinted = false
        for reminder in reminders {
            let key = Key(reminder.kind, reminder.sessionId)
            guard key != reopened else { continue }
            hintedKeys.insert(key)
            hinted = true
        }
        if hinted { hintPulse += 1 }

        // Same sound as the original event, once per kind per tick — a turn
        // that died rings the error jingle again, not "done" (AttentionPolicy's
        // `.reminderDue`). The regular gates (master switch, per-event toggle)
        // still apply: SoundManager holds the cue to the policy's sound rules
        // (but not to the turn-failure debounce, which is for real failures).
        var sounds: [String] = []
        for reminder in reminders {
            guard let sound = AttentionPolicy.intents(
                for: .reminderDue(reminder.kind, turnFailed: reminder.turnFailed)
            ).sound else { continue }
            if !sounds.contains(sound) { sounds.append(sound) }
        }
        sounds.forEach(playSound)
    }

    /// Re-open the item's card, honouring the same switch the first card did:
    /// with "auto-expand on approval" / "auto-expand on question" off, the
    /// item only chimes and hints (a question keeps its click-to-open badge).
    private func reopenCard(for reminder: FollowUpReminder) -> Bool {
        guard let appState else { return false }
        let sid = reminder.sessionId
        switch reminder.kind {
        case .approval:
            guard AppState.autoExpandOnPermission() else { return false }
            appState.activeSessionId = sid
            withAnimation(NotchAnimation.open) { appState.surface = .approvalCard(sessionId: sid) }
            return true
        case .question:
            guard AppState.autoExpandOnQuestion() else { return false }
            appState.activeSessionId = sid
            withAnimation(NotchAnimation.open) { appState.surface = .questionCard(sessionId: sid) }
            return true
        case .completion:
            return false
        }
    }

    private func notify(_ reminder: FollowUpReminder) {
        for handler in handlers { handler(reminder) }
    }

    /// Hand a reminder the island keeps to itself to the handlers, flagged
    /// `locallySuppressed`; returns whether one of them delivered it.
    private func offerSuppressed(_ reminder: FollowUpReminder) -> Bool {
        remoteDeliveries.removeAll()
        defer { remoteDeliveries.removeAll() }
        notify(reminder.suppressedLocally())
        return remoteDeliveries.contains(Key(reminder.kind, reminder.sessionId))
    }

    private func reschedule(now: Date) {
        var wake = scheduler.nextWakeDate()
        if scheduler.hasOwed {
            // Quiet hours end — and an unlock notification can go missing —
            // without an event to hear, so look again in a minute while
            // something is owed.
            let recheck = now.addingTimeInterval(60)
            wake = wake.map { min($0, recheck) } ?? recheck
        }
        guard wake != armedWakeDate else { return }
        disarm()
        armedWakeDate = wake
        guard let wake, armsTimer else { return }
        let delay = max(0, wake.timeIntervalSince(now))
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.armedWakeDate = nil
            await self.tick()
        }
    }

    private func disarm() {
        wakeTask?.cancel()
        wakeTask = nil
        armedWakeDate = nil
    }
}
