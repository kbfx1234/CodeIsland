import Foundation
import CoreGraphics
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "Push")

/// What `PushNotifier.notify` did with one moment.
enum PushDecision: Equatable {
    /// Push notifications are switched off.
    case disabled
    case skipped(PushSkipReason)
    /// Handed to these channels. Delivery itself is asynchronous; its outcome
    /// lands in `PushNotifier.lastDelivery`.
    case sent([PushChannelKind])
}

/// Last outcome per channel. Shown under the channel in Settings, so a push
/// that failed at 3 a.m. is visible without waiting for the next one.
struct PushDeliveryRecord: Equatable {
    let date: Date
    let kind: PushEventKind?  // nil = "Send test"
    let result: PushDeliveryResult
}

/// The approval or question a push is about, so the notifier can tell when
/// it has been answered.
struct PushPendingRequest {
    /// Identity within its session and kind: the tool call id when the
    /// agent sends one, else a fingerprint of what is asked.
    let key: String
    /// What is waiting under this identity right now, rebuilt from the
    /// queue (or the display-only wait); nil once it was answered or dropped.
    let current: @MainActor () -> PushContent?
}

/// Sends pushes to a phone or a team chat. Decides once per moment (channel
/// selection → gate → global cap → dedupe), then hands the push to every
/// channel that takes the kind, through that channel's queue (its own rate
/// limit, one retry for pushes that must not get lost). Fire-and-forget
/// like the webhook: a slow or failing push server never touches the hook
/// pipeline, it only updates `lastDelivery`.
///
/// Entry points:
/// - `notify(_:subject:…)` for any structured content;
/// - `AppState.pushFollowUpReminder(_:)`, subscribed to
///   `FollowUpReminderController` by `connectPushToFollowUps()`;
/// - `sendTest(_:)` for the settings page.
@MainActor
final class PushNotifier: ObservableObject {
    static let shared = PushNotifier()

    /// The only path to the network. Tests replace it with a recorder.
    var transport: PushTransport = URLSessionPushTransport.shared
    var presence: () -> PushPresenceSnapshot = { PushPresence.current() }
    var clock: () -> Date = Date.init
    var defaults: UserDefaults = .standard

    @Published private(set) var lastDelivery: [PushChannelKind: PushDeliveryRecord] = [:]
    /// The most recent `notify` verdict, for diagnostics and tests.
    private(set) var lastDecision: PushDecision?
    private var deduplicator = PushDeduplicator()

    /// Approvals / questions not yet seen answered, in one of two states:
    ///
    /// - pushed: holds its dedupe slot until `requestsChanged` finds it
    ///   gone, so a replay stays one push while the same request waits, and
    ///   the next one after it is answered is news even seconds later;
    /// - held back: skipped because someone was at the Mac (only-when-away,
    ///   or Smart Suppress). Pushed once when they leave — see Catch-up.
    private var tracked: [String: TrackedRequest] = [:]
    private var pruneScheduled = false

    private struct TrackedRequest {
        let kind: PushEventKind
        let subject: PushSubject
        let request: PushPendingRequest
        var heldBack: Bool
    }

    /// When the one catch-up timer fires, nil while none is armed. Armed
    /// only while something is held back.
    private(set) var catchUpWakeDate: Date?
    /// Tests call `catchUpIfAway()` by hand and turn the real timer off.
    var armsCatchUpTimer = true
    private var catchUpTask: Task<Void, Never>?

    private init() {}

    /// The approval / question queues or a display-only wait changed. The
    /// check runs on the next main-actor turn, once the change has settled:
    /// a queue is emptied and refilled in one go when a request is replayed
    /// or promoted, and that must not read as "answered". One flag check
    /// when nothing is tracked.
    func requestsChanged() {
        guard !tracked.isEmpty, !pruneScheduled else { return }
        pruneScheduled = true
        Task { @MainActor [weak self] in self?.forgetAnsweredRequests() }
    }

    /// Drops every tracked request that is no longer waiting: a pushed one
    /// frees its dedupe slot, a held-back one needs no catch-up any more.
    func forgetAnsweredRequests() {
        pruneScheduled = false
        for (id, entry) in tracked where entry.request.current() == nil {
            tracked[id] = nil
            deduplicator.forget(kind: entry.kind, sessionId: entry.subject.sessionId, requestKey: entry.request.key)
        }
        if !hasHeldBackRequests { disarmCatchUpTimer() }
    }

    // MARK: Catch-up

    /// An approval arrives 30 s after the user walked off without locking:
    /// "only when away" sees 30 s of idle, and it is skipped. Without a
    /// catch-up it would never reach the phone (follow-up reminders are off
    /// by default). So a held-back request is pushed once, as soon as the
    /// person is away: at the lock screen / screen saver / display sleep
    /// (`userLeft`), or when idle time reaches the threshold — checked by a
    /// single timer that exists only while something is held back.
    var hasHeldBackRequests: Bool { tracked.values.contains { $0.heldBack } }

    /// Lock screen, screen saver or display sleep just began.
    func userLeft() {
        guard hasHeldBackRequests else { return }
        catchUpHeldBack()
    }

    /// The catch-up timer: push what was held back if the person is away by
    /// now, else look again when they next could be.
    func catchUpIfAway() {
        catchUpWakeDate = nil
        catchUpTask = nil
        guard hasHeldBackRequests else { return }
        let snapshot = presence()
        if snapshot.isAway(idleThreshold: idleThreshold) {
            catchUpHeldBack()
        } else {
            armCatchUpTimer(presence: snapshot)
        }
    }

    /// Each held-back request still waiting is pushed with what it asks now;
    /// one pushed is an ordinary pushed request from then on, so it is never
    /// caught up twice.
    private func catchUpHeldBack() {
        for (id, entry) in tracked where entry.heldBack {
            guard let content = entry.request.current() else {
                tracked[id] = nil
                continue
            }
            let decision = decide(
                content,
                subject: entry.subject,
                smartSuppressed: false,
                isSubagent: false,
                interrupted: false,
                request: entry.request
            )
            lastDecision = decision
            switch decision {
            case .sent, .skipped(.duplicate):
                tracked[id]?.heldBack = false
            case .skipped(.userPresent), .skipped(.smartSuppressed):
                break  // back already; wait for the next departure
            default:
                tracked[id] = nil  // switched off, or no channel takes it any more
            }
        }
        if hasHeldBackRequests {
            armCatchUpTimer(presence: presence())
        } else {
            disarmCatchUpTimer()
        }
    }

    private func holdBack(_ id: String, _ entry: TrackedRequest, presence snapshot: PushPresenceSnapshot) {
        guard tracked[id] == nil else { return }
        tracked[id] = entry
        armCatchUpTimer(presence: snapshot)
    }

    /// One timer, due when the idle time could first reach the threshold.
    private func armCatchUpTimer(presence snapshot: PushPresenceSnapshot) {
        guard catchUpWakeDate == nil else { return }
        let delay = max(idleThreshold - snapshot.idleSeconds, 0) + 1
        catchUpWakeDate = clock().addingTimeInterval(delay)
        guard armsCatchUpTimer else { return }
        catchUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.catchUpIfAway()
        }
    }

    private func disarmCatchUpTimer() {
        catchUpTask?.cancel()
        catchUpTask = nil
        catchUpWakeDate = nil
    }

    private static func trackingId(_ kind: PushEventKind, _ sessionId: String, _ key: String) -> String {
        "\(kind.rawValue)|\(sessionId)|\(key)"
    }

    // MARK: Turn ends

    /// When a push of each kind last reached at least one channel, per
    /// session ("kind|session"). Delivered, not merely admitted: a push that
    /// failed on every channel told nobody anything.
    private var delivered: [String: Date] = [:]
    /// When each session's turn last ended on an error, pushed or not.
    private var turnFailures: [String: Date] = [:]
    /// How long both are remembered — past any follow-up interval.
    private static let turnMemory: TimeInterval = 3_600

    /// Whether the one reminder for a finished turn nobody looked at should
    /// be skipped: its completion push already reached the phone (the
    /// nudge would only repeat it), or the turn ended on an error — "still
    /// waiting · finished" would misreport a failed turn, whether or not
    /// its error push went out.
    func shouldSkipCompletionReminder(sessionId: String, since date: Date) -> Bool {
        if let failed = turnFailures[sessionId], failed >= date { return true }
        guard let sent = delivered["\(PushEventKind.completion.rawValue)|\(sessionId)"] else { return false }
        return sent >= date
    }

    private func noteDelivered(_ kind: PushEventKind, sessionId: String, at date: Date) {
        delivered = delivered.filter { date.timeIntervalSince($0.value) < Self.turnMemory }
        delivered["\(kind.rawValue)|\(sessionId)"] = date
    }

    private func noteTurnFailed(sessionId: String, at date: Date) {
        turnFailures = turnFailures.filter { date.timeIntervalSince($0.value) < Self.turnMemory }
        turnFailures[sessionId] = date
    }

    // MARK: Settings

    var isEnabled: Bool { defaults.bool(forKey: SettingsKey.pushEnabled) }

    /// `bool(forKey:)` reads an unregistered key as false; this one defaults on.
    var onlyWhenAway: Bool {
        defaults.object(forKey: SettingsKey.pushOnlyWhenAway) == nil
            ? SettingsDefaults.pushOnlyWhenAway
            : defaults.bool(forKey: SettingsKey.pushOnlyWhenAway)
    }

    var idleThreshold: TimeInterval {
        let minutes = defaults.object(forKey: SettingsKey.pushAwayIdleMinutes) == nil
            ? SettingsDefaults.pushAwayIdleMinutes
            : defaults.integer(forKey: SettingsKey.pushAwayIdleMinutes)
        return TimeInterval(max(minutes, 1) * 60)
    }

    var summaryLimit: Int {
        let stored = defaults.integer(forKey: SettingsKey.pushSummaryLength)
        return stored > 0 ? stored : SettingsDefaults.pushSummaryLength
    }

    var channels: [PushChannelConfig] {
        PushChannelConfig.decodeList(defaults.string(forKey: SettingsKey.pushChannels) ?? SettingsDefaults.pushChannels)
    }

    // MARK: Sending

    /// Decide and, if it passes, send. Cheap when disabled: one defaults read.
    ///
    /// - `smartSuppressed`: the island itself declined to pop this up
    ///   because the agent's terminal is in front (Smart Suppress).
    /// - `isSubagent` / `interrupted`: only meaningful for completions.
    /// - `request`: the approval / question this push is about, for
    ///   `.permission` / `.question` content; nil otherwise.
    @discardableResult
    func notify(
        _ content: PushContent,
        subject: PushSubject,
        smartSuppressed: @autoclosure () -> Bool = false,
        isSubagent: Bool = false,
        interrupted: Bool = false,
        request: PushPendingRequest? = nil
    ) -> PushDecision {
        if content.kind == .error, isEnabled {
            noteTurnFailed(sessionId: subject.sessionId, at: clock())
        }
        let decision = decide(
            content,
            subject: subject,
            smartSuppressed: smartSuppressed(),
            isSubagent: isSubagent,
            interrupted: interrupted,
            request: request
        )
        lastDecision = decision
        return decision
    }

    private func decide(
        _ content: PushContent,
        subject: PushSubject,
        smartSuppressed: @autoclosure () -> Bool,
        isSubagent: Bool,
        interrupted: Bool,
        request: PushPendingRequest?
    ) -> PushDecision {
        guard isEnabled else { return .disabled }
        let kind = content.kind
        // A turn that ended on an error is still a turn end: a channel that
        // only takes finished turns hears about it too, as the error.
        let targets = channels.filter { $0.accepts(kind) || (kind == .error && $0.accepts(.completion)) }
        guard !targets.isEmpty else { return skip(.noChannel, kind, subject) }

        let gate = PushGateInput(
            kind: kind,
            onlyWhenAway: onlyWhenAway,
            idleThreshold: idleThreshold,
            presence: presence(),
            smartSuppressed: smartSuppressed(),
            isSubagent: isSubagent,
            interrupted: interrupted
        )
        let request = kind == .permission || kind == .question ? request : nil
        let trackingId = request.map { Self.trackingId(kind, subject.sessionId, $0.key) }
        if let reason = PushGate.evaluate(gate) {
            if let request, let trackingId, reason == .userPresent || reason == .smartSuppressed {
                holdBack(
                    trackingId,
                    TrackedRequest(kind: kind, subject: subject, request: request, heldBack: true),
                    presence: gate.presence
                )
            }
            return skip(reason, kind, subject)
        }

        let now = clock()
        if !PushThrottle.mustDeliver(kind), globalLimiter.nextSlot(now: now) > now {
            return skip(.rateLimited, kind, subject)
        }
        if let reason = deduplicator.admit(kind: kind, sessionId: subject.sessionId, requestKey: request?.key, now: now) {
            return skip(reason, kind, subject)
        }
        // Approvals and questions neither wait for nor use up the global cap.
        if !PushThrottle.mustDeliver(kind) { globalLimiter.record(now) }
        if let request, let trackingId {
            tracked[trackingId] = TrackedRequest(kind: kind, subject: subject, request: request, heldBack: false)
        }

        // Rendered once per detail level; team chats default to headlines only.
        var rendered: [Bool: PushMessage] = [:]
        for channel in targets {
            let message = rendered[channel.includeDetails] ?? PushMessageFormatter.render(
                content,
                subject: subject,
                strings: Self.strings(),
                summaryLimit: summaryLimit,
                includeDetails: channel.includeDetails,
                now: now
            )
            rendered[channel.includeDetails] = message
            enqueue(Outgoing(
                message: message,
                channel: channel,
                kind: kind,
                requestId: trackingId,
                attempt: 0,
                notBefore: now,
                enqueued: now
            ))
        }
        log.info("push \(kind.rawValue, privacy: .public) session=\(subject.sessionId, privacy: .public) → \(targets.map(\.kind.rawValue).joined(separator: ","), privacy: .public)")
        return .sent(targets.map(\.kind))
    }

    // MARK: Outbox

    /// One push on its way to one channel.
    private struct Outgoing {
        let message: PushMessage
        let channel: PushChannelConfig
        /// What the push is about (`PushContent.kind`).
        let kind: PushEventKind
        /// The approval / question it asks about (`tracked` key), so a push
        /// still queued when it is answered is dropped instead of sent.
        let requestId: String?
        var attempt: Int
        var notBefore: Date
        let enqueued: Date
    }

    /// Per channel, what still waits for its moment (a retry) or for room
    /// under the channel's own rate limit. Personal channels have no limit,
    /// so theirs goes out on the spot and never lingers here.
    private var outbox: [PushChannelKind: [Outgoing]] = [:]
    private var channelLimiters: [PushChannelKind: PushRateLimiter] = [:]
    private var globalLimiter = PushRateLimiter(windows: [PushThrottle.global])
    private var outboxWake: [PushChannelKind: Date] = [:]
    private var outboxTasks: [PushChannelKind: Task<Void, Never>] = [:]
    /// Waits out a retry delay or a rate-limit slot. Tests replace it.
    var sleep: @MainActor (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }

    private func enqueue(_ item: Outgoing) {
        outbox[item.channel.kind, default: []].append(item)
        pump(item.channel.kind, now: clock())
    }

    /// Sends what is due and fits the channel's limit, oldest first; keeps
    /// the rest and arms one wake-up for the earliest of them. Over the
    /// limit, an approval or question waits for room; anything else waits
    /// only a few seconds (per-second limits) and is otherwise dropped.
    private func pump(_ channelKind: PushChannelKind, now: Date) {
        guard let queue = outbox[channelKind], !queue.isEmpty else { return }
        var limiter = channelLimiters[channelKind] ?? PushRateLimiter(windows: channelKind.rateLimits)
        var waiting: [Outgoing] = []
        var wake: Date?
        for item in queue {
            if item.notBefore > now {
                waiting.append(item)
                wake = min(wake ?? item.notBefore, item.notBefore)
                continue
            }
            if let id = item.requestId, tracked[id] == nil {
                log.info("push \(item.kind.rawValue, privacy: .public) to \(channelKind.rawValue, privacy: .public) dropped: answered while queued")
                continue
            }
            let slot = limiter.nextSlot(now: now)
            if slot > now {
                if PushThrottle.mustDeliver(item.kind)
                    || slot.timeIntervalSince(item.enqueued) <= PushThrottle.dropGrace {
                    waiting.append(item)
                    wake = min(wake ?? slot, slot)
                } else {
                    log.info("push \(item.kind.rawValue, privacy: .public) to \(channelKind.rawValue, privacy: .public) dropped: over the channel's rate limit")
                }
                continue
            }
            limiter.record(now)
            transmit(item)
        }
        channelLimiters[channelKind] = limiter
        outbox[channelKind] = waiting.isEmpty ? nil : waiting
        armOutbox(channelKind, at: wake)
    }

    private func armOutbox(_ channelKind: PushChannelKind, at wake: Date?) {
        guard let wake else {
            outboxTasks[channelKind]?.cancel()
            outboxTasks[channelKind] = nil
            outboxWake[channelKind] = nil
            return
        }
        if let armed = outboxWake[channelKind], armed <= wake { return }
        outboxTasks[channelKind]?.cancel()
        outboxWake[channelKind] = wake
        let delay = wake.timeIntervalSince(clock())
        outboxTasks[channelKind] = Task { @MainActor [weak self] in
            await self?.sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.outboxWake[channelKind] = nil
            self.outboxTasks[channelKind] = nil
            // Never before the wake it slept for, so a shortened sleep
            // (tests) still moves on.
            self.pump(channelKind, now: max(self.clock(), wake))
        }
    }

    /// Builds the request at send time — DingTalk and Feishu signatures carry
    /// a timestamp — and records the server's verdict.
    private func transmit(_ item: Outgoing) {
        let channel = item.channel
        let request: PushHTTPRequest
        do {
            request = try PushRequestBuilder.request(for: item.message, channel: channel, now: clock())
        } catch {
            lastDelivery[channel.kind] = PushDeliveryRecord(date: clock(), kind: item.kind, result: Self.configFailure(error))
            return
        }
        let transport = self.transport
        Task { [weak self] in
            let response = await transport.send(request)
            let result = PushDeliveryResult.from(response, kind: channel.kind, requestURL: request.url)
            if !result.ok {
                log.error("push to \(channel.kind.rawValue, privacy: .public) failed: \(result.loggableSummary(for: channel), privacy: .public)")
            }
            guard let self else { return }
            self.lastDelivery[channel.kind] = PushDeliveryRecord(date: self.clock(), kind: item.kind, result: result)
            if result.ok {
                self.noteDelivered(item.kind, sessionId: item.message.sessionId, at: item.enqueued)
            }
            self.retryIfWorthIt(item, after: response, ok: result.ok)
        }
    }

    /// Approvals, questions and errors get one more try after a network
    /// failure, a 5xx or a 429 — through the same queue, so the channel's
    /// rate limit still holds and an approval answered meanwhile is dropped.
    private func retryIfWorthIt(_ item: Outgoing, after response: PushTransportResponse, ok: Bool) {
        guard !ok, item.attempt == 0, PushRetryPolicy.retries(item.kind),
              let delay = PushRetryPolicy.delay(after: response) else { return }
        var retry = item
        retry.attempt += 1
        retry.notBefore = clock().addingTimeInterval(delay)
        log.info("push \(item.kind.rawValue, privacy: .public) to \(item.channel.kind.rawValue, privacy: .public): retrying in \(Int(delay))s")
        enqueue(retry)
    }

    /// "Send test": bypasses every gate and the dedupe, and reports exactly
    /// what the server said.
    func sendTest(_ channel: PushChannelConfig) async -> PushDeliveryResult {
        let message = PushMessage.test(strings: Self.strings())
        let result: PushDeliveryResult
        do {
            let request = try PushRequestBuilder.request(for: message, channel: channel, now: clock())
            let response = await transport.send(request)
            result = .from(response, kind: channel.kind, requestURL: request.url)
        } catch {
            result = Self.configFailure(error)
        }
        lastDelivery[channel.kind] = PushDeliveryRecord(date: clock(), kind: nil, result: result)
        return result
    }

    private func skip(_ reason: PushSkipReason, _ kind: PushEventKind, _ subject: PushSubject) -> PushDecision {
        log.debug("push \(kind.rawValue, privacy: .public) session=\(subject.sessionId, privacy: .public) skipped: \(reason.rawValue, privacy: .public)")
        return .skipped(reason)
    }

    private static func configFailure(_ error: Error) -> PushDeliveryResult {
        let problem = (error as? PushConfigProblem) ?? .invalidURL
        return PushDeliveryResult(ok: false, statusCode: nil, message: L10n.shared["push_problem_\(problem.rawValue)"])
    }

    static func strings(_ l10n: L10n = .shared) -> PushStrings {
        PushStrings(
            permission: l10n["push_msg_permission"],
            question: l10n["push_msg_question"],
            completion: l10n["push_msg_completion"],
            error: l10n["push_msg_error"],
            reminder: l10n["push_msg_reminder"],
            waitingMinutes: l10n["push_msg_waiting_minutes"],
            secretQuestion: l10n["push_msg_secret_question"],
            moreOptions: l10n["push_msg_more_options"],
            testHeadline: l10n["push_msg_test_headline"],
            testBody: l10n["push_msg_test_body"],
            answerIn: l10n["push_msg_answer_in"],
            answerOnMac: l10n["push_msg_answer_on_mac"]
        )
    }

    /// Clears dedupe state and delivery records between tests.
    func resetForTesting() {
        deduplicator = PushDeduplicator()
        lastDelivery = [:]
        lastDecision = nil
        tracked = [:]
        pruneScheduled = false
        delivered = [:]
        turnFailures = [:]
        disarmCatchUpTimer()
        outboxTasks.values.forEach { $0.cancel() }
        outboxTasks = [:]
        outboxWake = [:]
        outbox = [:]
        channelLimiters = [:]
        globalLimiter = PushRateLimiter(windows: [PushThrottle.global])
        sleep = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    }
}

// MARK: - Presence

/// "Is anyone at this Mac", for the push gate. Lock, screen saver and display
/// sleep are the signals `SceneMuteMonitor` already tracks for event sounds;
/// idle time and fast user switching are read on demand. Nothing here needs a
/// permission or an observer of its own.
enum PushPresence {
    @MainActor
    static func current() -> PushPresenceSnapshot {
        let scene = SceneMuteMonitor.shared.state
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // Another user owns the console: this one is not at the screen.
        let onConsole = session?["kCGSSessionOnConsoleKey"] as? Bool ?? true
        // ~0 is kCGAnyInputEventType: keyboard, mouse, trackpad, tablet.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return PushPresenceSnapshot(
            screenLocked: scene.screenLocked,
            screenSaverRunning: scene.screensaverRunning,
            displaysAsleep: scene.displaysAsleep,
            sessionOnConsole: onConsole,
            idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        )
    }
}
