import Foundation

/// Should this get the user's attention, and how?
///
/// Every way the island has of saying "look at this" — an event sound, the
/// completion card, a push to a phone or a team chat, a follow-up reminder —
/// is decided here, once per moment, in two steps:
///
/// 1. ``intents(for:subject:)``: what the moment calls for on its own. A
///    failed tool call is not news, a turn that died is; a child session's
///    turn is its parent's business; a gateway chat is not news at the desk.
/// 2. ``settle(_:context:)``: what the user's settings and the room allow
///    right now — the sound switches, quiet hours and the lock screen, the
///    completion style, Smart Suppress, push being on at all.
///
/// ``decide(_:subject:context:)`` runs both. Each outlet keeps only its own
/// delivery mechanics: the turn-failure jingle's debounce (SoundManager), the
/// completion card queue and Smart Suppress's look as a card shows (AppState),
/// presence, channels, rate limits and dedupe (PushNotifier, `PushGate`), and
/// the reminder clock (FollowUpReminderController).
///
/// A new rule ("this never rings", "that never pushes") belongs here, with a
/// row in AttentionPolicyTests — not in the reducer or at a call site.
public enum AttentionPolicy {
    /// What `moment` calls for, before the user's settings and the room have
    /// their say.
    public static func intents(
        for moment: AttentionMoment,
        subject: AttentionSubject = AttentionSubject()
    ) -> AttentionIntents {
        switch moment {
        case .hookEvent(let facts):
            return hookEventIntents(facts, subject: subject)

        case .approvalQueued(let firstOfBurst):
            // The chime marks the start of a burst of approvals: three queued
            // back to back are one interruption, not three (#309, #312). The
            // push is per request; its dedupe tells replays apart.
            return AttentionIntents(
                sound: firstOfBurst ? SoundCue.request : nil,
                push: .init(kind: .approval)
            )

        case .questionQueued(let firstOfBurst, let smartSuppressible):
            return AttentionIntents(
                sound: firstOfBurst ? SoundCue.request : nil,
                push: .init(kind: .question, smartSuppressible: smartSuppressible)
            )

        case .requestRaisedElsewhere:
            // Nothing is queued — the answer can only be given where it was
            // asked — so the sound is what says the agent is blocked (#265).
            // Its push and reminders follow the wait itself
            // (`displayOnlyWaitBegan`).
            return AttentionIntents(sound: SoundCue.request)

        case .displayOnlyWaitBegan(let kind, let announce):
            // Reminders start over for every wait that begins. Only a live
            // wait from a source the island can never own is pushed: a launch
            // rebuild or a backfill is old news, and a terminal
            // `permission_prompt` races its own PermissionRequest hook, whose
            // richer push would lose its dedupe slot to this one.
            return AttentionIntents(
                push: announce ? .init(kind: .displayOnlyWait) : nil,
                followUp: .restartWait(kind)
            )

        case .turnStarted(let newSession):
            guard !subject.isChild else { return AttentionIntents() }
            return AttentionIntents(sound: newSession ? SoundCue.sessionStart : SoundCue.prompt)

        case .turnEnded(let end, let host):
            guard !subject.isChild else { return AttentionIntents() }
            switch end {
            case .completed:
                return finishedTurnIntents(turnFailed: false, subject: subject)
            case .failed:
                return finishedTurnIntents(turnFailed: true, subject: subject)
            case .stopped:
                switch host {
                case .claudeDesktop:
                    // Claude Desktop's Stop button: the user is right there and
                    // knows. No jingle, no completion card, no push, no follow-up;
                    // the card just reads interrupted.
                    return AttentionIntents()
                case .aiwork:
                    // `stream.aborted` has always popped its card (it reads
                    // "interrupted"), like an Esc in a hook-driven agent — but
                    // it rings nothing, pushes nothing and is not followed up.
                    return AttentionIntents(completion: .init(turnFailed: false))
                }
            }

        case .reminderDue(let kind, let turnFailed):
            // The same sound as the moment it reminds of: a turn that died
            // rings the error jingle again, not "done".
            switch kind {
            case .approval, .question:
                return AttentionIntents(sound: SoundCue.request)
            case .completion:
                return AttentionIntents(sound: turnFailed ? SoundCue.turnFailed : SoundCue.turnEnd)
            }

        case .appLaunched:
            return AttentionIntents(sound: SoundCue.launch)
        }
    }

    /// What actually happens, given the user's settings and the room.
    ///
    /// The context's lazy facts are read only when a decision depends on them.
    public static func settle(_ intents: AttentionIntents, context: AttentionContext) -> AttentionDecision {
        var decision = AttentionDecision()
        decision.sound = audibleSound(intents.sound, sounds: context.sounds, hold: context.soundHold)

        if let completion = intents.completion {
            let presentation: CompletionPresentation
            switch context.completionStyle {
            case .off:
                // The panel stays compact — the session card still updates
                // (and reads ERROR after a failed turn), but nothing pops (#146).
                presentation = .statusOnly
            case .glance:
                presentation = .glance
            case .expand:
                // Smart Suppress is asked when the card is about to show — at
                // once, or later from the queue — not now: a card that waits
                // behind another one is shown into a different moment.
                presentation = .card
            }
            decision.completion = .init(turnFailed: completion.turnFailed, presentation: presentation)
        }

        if let push = intents.push, context.pushEnabled {
            decision.push = .init(
                kind: push.kind,
                smartSuppressed: push.smartSuppressible && context.sessionInFront()
            )
        }

        switch intents.followUp {
        case .trackCompletion?:
            // Follow-ups only chase completions the user asked to hear about.
            decision.followUp = context.completionStyle == .off ? nil : intents.followUp
        case .restartWait?, nil:
            decision.followUp = intents.followUp
        }
        return decision
    }

    /// ``intents(for:subject:)`` settled against `context`.
    public static func decide(
        _ moment: AttentionMoment,
        subject: AttentionSubject = AttentionSubject(),
        context: AttentionContext
    ) -> AttentionDecision {
        settle(intents(for: moment, subject: subject), context: context)
    }

    /// The sound a cue plays as the user set things up: the master switch and
    /// the cue's own switch (a cue with no sound of its own — most hook
    /// events — is never audible), then anything holding sounds back. The
    /// hold comes last because reading the lock state is a WindowServer round
    /// trip, which a silent tool step must not pay on the main thread.
    public static func audibleSound(_ cue: String?, sounds: SoundPreferences, hold: SoundHold) -> String? {
        guard let cue, sounds.enabled, sounds.audibleCues.contains(cue) else { return nil }
        guard !holdsSounds(hold) else { return nil }
        return cue
    }

    /// Whether event sounds are held back right now, for a reason that will
    /// pass on its own: quiet hours, or — with "mute when away" on — nobody
    /// at the screen (locked, or the screen saver running; displays that only
    /// went to sleep do not count, see `SceneMuteState`). Follow-up reminders
    /// wait out the same hold and catch up afterwards.
    public static func holdsSounds(_ hold: SoundHold) -> Bool {
        hold.quietHours() || (hold.muteWhenAway && hold.sceneQuiet())
    }

    // MARK: - Hook events

    private static func hookEventIntents(_ facts: HookEventFacts, subject: AttentionSubject) -> AttentionIntents {
        // A session another agent spawned works for that agent's turn: its
        // own start, prompt, turn end and failure are the parent's business,
        // not the user's — the user hears the parent finish (#378). Its
        // approvals and questions arrive as their own moments and still alert.
        guard !subject.isChild else { return AttentionIntents() }
        // A conversation held somewhere else — a Hermes gateway chat, the API
        // server, a background run: its card follows along, but a bot
        // answering on Telegram isn't news at the desk (#364).
        guard !facts.heldElsewhere else { return AttentionIntents() }

        // A single failed tool call stays silent; only a turn that died
        // (StopFailure) rings the error sound. See EventSoundRouting.
        let cue = EventSoundRouting.soundEvent(rawEventName: facts.rawEventName, normalizedEventName: facts.eventName)
        var intents = AttentionIntents()
        // Only an event that moved the session itself rings: not one dropped
        // as stale, filed under a subagent, or ending the session. A turn the
        // user stopped (Esc / Ctrl-C, Cline's cancel) ends without a chime:
        // it did not complete, and the user knows — its card still pops.
        if facts.appliedToSession, !(facts.endedTurn && subject.interrupted) {
            intents.sound = cue
        }
        if facts.endedTurn {
            // The normalizer folds StopFailure onto Stop; only the raw name
            // says the turn died (same rule as its sound).
            let turnFailed = cue == EventSoundRouting.turnFailed
            intents.completion = .init(turnFailed: turnFailed)
            intents.followUp = followUp(turnFailed: turnFailed, subject: subject)
        }
        // A turn that stopped on an error pushes the error instead of a
        // completion: one push for one failed turn. Only the session's own
        // turn, though: a subagent's failure filed under the session (or a
        // stale one) is not its error, and pushed under its name it would
        // shadow the session's own completion push a moment later.
        if facts.turnError != nil {
            if facts.appliedToSession {
                intents.push = .init(kind: .error)
            }
        } else if facts.endedTurn {
            intents.push = .init(kind: .completion(isSubagent: facts.subagentTurn, interrupted: subject.interrupted))
        }
        return intents
    }

    /// A turn that finished in a source the hook reducer never sees. One the
    /// user stopped ends without a chime there too.
    private static func finishedTurnIntents(turnFailed: Bool, subject: AttentionSubject) -> AttentionIntents {
        AttentionIntents(
            sound: subject.interrupted ? nil : turnFailed ? SoundCue.turnFailed : SoundCue.turnEnd,
            completion: .init(turnFailed: turnFailed),
            push: .init(kind: turnFailed
                ? .error
                : .completion(isSubagent: false, interrupted: subject.interrupted)),
            followUp: followUp(turnFailed: turnFailed, subject: subject)
        )
    }

    /// One nudge for a finished turn nobody looked at — unless the user
    /// stopped it themselves: an interrupted turn is not news to anyone.
    private static func followUp(turnFailed: Bool, subject: AttentionSubject) -> FollowUpIntent? {
        subject.interrupted ? nil : .trackCompletion(turnFailed: turnFailed)
    }
}

// MARK: - Sound cues

/// The sound cues the policy speaks in: event names, as `SoundManager` keys
/// its sounds and the per-event switches. A hook event's cue is its own
/// (normalized) name, see `EventSoundRouting`.
public enum SoundCue {
    /// An approval or a question needs the user ("approval needed").
    public static let request = "PermissionRequest"
    public static let sessionStart = "SessionStart"
    public static let prompt = "UserPromptSubmit"
    /// A turn finished.
    public static let turnEnd = "Stop"
    /// A turn died on an error rather than ending with a reply.
    public static let turnFailed = EventSoundRouting.turnFailed
    /// The app was launched by the user.
    public static let launch = "AppLaunch"
}

// MARK: - Moments

/// Something that happened which may deserve the user's attention.
public enum AttentionMoment: Equatable, Sendable {
    /// A hook event, as the reducer applied it (``reduceHookEvent``).
    case hookEvent(HookEventFacts)
    /// The island queued an approval. `firstOfBurst`: no other approval was
    /// visibly waiting (a dismissed one does not count, #309).
    case approvalQueued(firstOfBurst: Bool)
    /// The island queued a question: a Notification question, an
    /// AskUserQuestion wizard, Codex Desktop's request_user_input.
    /// `smartSuppressible`: false for Codex Desktop's app-server question,
    /// whose card and push have never been held back by Smart Suppress.
    case questionQueued(firstOfBurst: Bool, smartSuppressible: Bool = true)
    /// An agent got blocked on the user somewhere the island cannot answer
    /// for it (`DisplayOnlyWait`): Cursor's in-IDE question, a Claude Desktop
    /// permission card, an AiWork approval / plan confirmation / question.
    case requestRaisedElsewhere
    /// A session began waiting display-only on `kind`. `announce`: a live
    /// wait from a source the island can never own (Cowork, Cursor's
    /// question, AiWork) rather than a launch rebuild, a backfill, or a
    /// terminal prompt the island may still queue.
    case displayOnlyWaitBegan(FollowUpReminderKind, announce: Bool)
    /// A turn began in a source the hook reducer never sees.
    case turnStarted(newSession: Bool)
    /// A turn ended in a source the hook reducer never sees.
    case turnEnded(TurnEnd, host: TurnHost)
    /// A follow-up reminder came due and the island itself delivers it.
    case reminderDue(FollowUpReminderKind, turnFailed: Bool)
    /// The user launched the app (a launch at login stays silent before
    /// it gets here).
    case appLaunched
}

/// How a turn ended in a source that bypasses the hook reducer.
public enum TurnEnd: Equatable, Sendable {
    case completed
    /// On an error: a failed AiWork stream, a Cowork turn whose result is an error.
    case failed
    /// The user stopped it: Claude Desktop's Stop button, AiWork's `stream.aborted`.
    case stopped
}

/// Where a turn that bypasses the hook reducer ran.
public enum TurnHost: Equatable, Sendable {
    /// Claude Desktop (Cowork tasks), read from its session store.
    case claudeDesktop
    /// An AiWork / Agentix daemon (`sessions.watch`).
    case aiwork
}

/// What a hook event did, as the reducer reports it (``reduceHookEvent``).
public struct HookEventFacts: Equatable, Sendable {
    /// The event's name on the wire (`StopFailure`, `on_session_end`, …).
    public var rawEventName: String
    /// The island's name for it (`EventNormalizer`).
    public var eventName: String
    /// The event moved this session's own state. False when the reducer
    /// dropped it as stale (a finished Cline round, an interrupted Codex
    /// turn), filed it under one of the session's subagents, or ended the
    /// session with it (SessionEnd, a Hermes one-shot run's end).
    public var appliedToSession: Bool
    /// The event ended the session's turn with nothing left working under
    /// it: a Stop, an IDE's final AfterAgentResponse, a Cline task round, a
    /// Codex Interrupt.
    public var endedTurn: Bool
    /// A Hermes hook from a conversation nobody is having at this Mac
    /// (`HermesHookPayload.isQuiet`).
    public var heldElsewhere: Bool
    /// The error the turn stopped on (`PushEventClassifier.sessionError`).
    public var turnError: PushSessionError?
    /// The turn that ended is a subagent's rather than the conversation the
    /// user started (`PushEventClassifier.isSubagentCompletion`).
    public var subagentTurn: Bool

    public init(
        rawEventName: String,
        eventName: String? = nil,
        appliedToSession: Bool = false,
        endedTurn: Bool = false,
        heldElsewhere: Bool = false,
        turnError: PushSessionError? = nil,
        subagentTurn: Bool = false
    ) {
        self.rawEventName = rawEventName
        self.eventName = eventName ?? EventNormalizer.normalize(rawEventName)
        self.appliedToSession = appliedToSession
        self.endedTurn = endedTurn
        self.heldElsewhere = heldElsewhere
        self.turnError = turnError
        self.subagentTurn = subagentTurn
    }

    /// What the event says about itself, before the reducer has applied it.
    public init(event: HookEvent) {
        self.init(
            rawEventName: event.eventName,
            heldElsewhere: HermesHookPayload.isQuiet(event),
            turnError: PushEventClassifier.sessionError(eventName: event.eventName, raw: event.rawJSON)
        )
    }
}

/// What the rules read about the session a moment happened to.
public struct AttentionSubject: Equatable, Sendable {
    /// The session is a child another agent spawned, working for its parent:
    /// it names one (`SessionSnapshot.parentSessionId`), or the app just
    /// folded its card into its parent's.
    public var isChild: Bool
    /// The user stopped the session's turn (Esc / Ctrl-C).
    public var interrupted: Bool

    public init(isChild: Bool = false, interrupted: Bool = false) {
        self.isChild = isChild
        self.interrupted = interrupted
    }

    /// As `session` stands; a session the island no longer holds is nobody's child.
    public init(_ session: SessionSnapshot?) {
        self.init(
            isChild: session?.parentSessionId != nil,
            interrupted: session?.interrupted == true
        )
    }
}

// MARK: - Intents and decisions

/// What a push is about.
public enum AttentionPushKind: Equatable, Sendable {
    /// The turn ended on an error.
    case error
    /// The turn finished. A subagent's or an interrupted one is offered to
    /// the push gate all the same: `PushGate` turns both away and says why
    /// (`PushSkipReason.subagent`, `.interrupted`).
    case completion(isSubagent: Bool, interrupted: Bool)
    case approval
    case question
    /// A display-only wait began: answer it where it was asked.
    case displayOnlyWait
}

/// What a moment calls for (``AttentionPolicy/intents(for:subject:)``).
public struct AttentionIntents: Equatable, Sendable {
    /// The sound cue (a ``SoundCue`` or a hook event's name), or nil.
    public var sound: String?
    /// The moment finished a turn the island announces.
    public var completion: Completion?
    public var push: Push?
    public var followUp: FollowUpIntent?

    public struct Completion: Equatable, Sendable {
        public var turnFailed: Bool

        public init(turnFailed: Bool) {
            self.turnFailed = turnFailed
        }
    }

    public struct Push: Equatable, Sendable {
        public var kind: AttentionPushKind
        /// Smart Suppress may hold it back while the user is at the Mac.
        public var smartSuppressible: Bool

        public init(kind: AttentionPushKind, smartSuppressible: Bool = true) {
            self.kind = kind
            self.smartSuppressible = smartSuppressible
        }
    }

    public init(
        sound: String? = nil,
        completion: Completion? = nil,
        push: Push? = nil,
        followUp: FollowUpIntent? = nil
    ) {
        self.sound = sound
        self.completion = completion
        self.push = push
        self.followUp = followUp
    }
}

/// What happens (``AttentionPolicy/settle(_:context:)``).
public struct AttentionDecision: Equatable, Sendable {
    /// The cue to play — one the user hears right now — or nil.
    public var sound: String?
    public var completion: Completion?
    public var push: Push?
    public var followUp: FollowUpIntent?

    public struct Completion: Equatable, Sendable {
        /// The session card reads ERROR until the next prompt, and its
        /// follow-up says so.
        public var turnFailed: Bool
        public var presentation: CompletionPresentation

        public init(turnFailed: Bool, presentation: CompletionPresentation) {
            self.turnFailed = turnFailed
            self.presentation = presentation
        }
    }

    public struct Push: Equatable, Sendable {
        public var kind: AttentionPushKind
        /// Smart Suppress kept the island quiet: the session's terminal is in
        /// front. `PushGate` honours it only while someone is at the Mac — a
        /// locked Mac keeps reporting its last frontmost app.
        public var smartSuppressed: Bool

        public init(kind: AttentionPushKind, smartSuppressed: Bool) {
            self.kind = kind
            self.smartSuppressed = smartSuppressed
        }
    }

    public init(
        sound: String? = nil,
        completion: Completion? = nil,
        push: Push? = nil,
        followUp: FollowUpIntent? = nil
    ) {
        self.sound = sound
        self.completion = completion
        self.push = push
        self.followUp = followUp
    }
}

/// How the island shows a finished turn.
public enum CompletionPresentation: Equatable, Sendable {
    /// Completion style "off": the session card updates, nothing pops.
    case statusOnly
    /// Completion style "glance": the collapsed island lights its dot.
    case glance
    /// Completion style "expand": the completion card pops, held to Smart
    /// Suppress when it is about to show (at once or from the queue): with
    /// the session's terminal in front, it stays down if the session's own
    /// tab is the one showing.
    case card
}

/// Follow-up reminder bookkeeping a moment starts.
public enum FollowUpIntent: Equatable, Sendable {
    /// One nudge for this finished turn if nobody looks at it.
    case trackCompletion(turnFailed: Bool)
    /// A display-only wait began: its reminders start over.
    case restartWait(FollowUpReminderKind)
}

// MARK: - Context

/// The three-way completion notification style (Settings › Behavior).
public enum CompletionStyle: String, Sendable {
    case expand, glance, off
}

/// The user's settings and the environment facts the policy reads, gathered
/// by the app per moment. Facts that cost something to read — the clock
/// against quiet hours, the lock state, the frontmost app — are closures,
/// read only when a decision depends on them.
public struct AttentionContext {
    public var sounds: SoundPreferences
    public var soundHold: SoundHold
    public var completionStyle: CompletionStyle
    /// Push notifications are switched on.
    public var pushEnabled: Bool
    /// Smart Suppress's app-level answer for the session: the setting is on
    /// and the session's own terminal (or host app) is in front. Read only
    /// for a push, at most once.
    public var sessionInFront: () -> Bool

    public init(
        sounds: SoundPreferences,
        soundHold: SoundHold,
        completionStyle: CompletionStyle,
        pushEnabled: Bool,
        sessionInFront: @escaping () -> Bool
    ) {
        self.sounds = sounds
        self.soundHold = soundHold
        self.completionStyle = completionStyle
        self.pushEnabled = pushEnabled
        self.sessionInFront = sessionInFront
    }
}

/// The standing sound choices: the master switch and the per-event switches.
public struct SoundPreferences: Equatable, Sendable {
    public var enabled: Bool
    /// The cues the user hears: each one that has a sound and whose own
    /// switch is on.
    public var audibleCues: Set<String>

    public init(enabled: Bool, audibleCues: Set<String>) {
        self.enabled = enabled
        self.audibleCues = audibleCues
    }
}

/// What may hold event sounds back for now (``AttentionPolicy/holdsSounds(_:)``).
public struct SoundHold {
    /// Inside the user's quiet-hours window (and the feature is on).
    public var quietHours: () -> Bool
    /// "Mute when away" is on.
    public var muteWhenAway: Bool
    /// The screen is locked or the screen saver runs (`SceneMuteState.isQuiet`).
    public var sceneQuiet: () -> Bool

    public init(quietHours: @escaping () -> Bool, muteWhenAway: Bool, sceneQuiet: @escaping () -> Bool) {
        self.quietHours = quietHours
        self.muteWhenAway = muteWhenAway
        self.sceneQuiet = sceneQuiet
    }
}
