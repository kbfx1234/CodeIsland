import XCTest
@testable import CodeIslandCore

/// Every rule of `AttentionPolicy`, one row each. The first table is what a
/// moment calls for on its own (`intents`); the second is what the user's
/// settings and the room let through (`settle`). A rule that changes should
/// change a row here, and a new one should add a row.
final class AttentionPolicyTests: XCTestCase {

    // MARK: - What a moment calls for

    private struct IntentRow {
        let rule: String
        let moment: AttentionMoment
        var subject = AttentionSubject()
        let expected: AttentionIntents
    }

    private static let child = AttentionSubject(isChild: true)
    private static let interrupted = AttentionSubject(interrupted: true)

    private static func hook(
        _ rawEventName: String,
        applied: Bool = true,
        endedTurn: Bool = false,
        heldElsewhere: Bool = false,
        error: PushSessionError? = nil,
        subagentTurn: Bool = false
    ) -> AttentionMoment {
        .hookEvent(HookEventFacts(
            rawEventName: rawEventName,
            appliedToSession: applied,
            endedTurn: endedTurn,
            heldElsewhere: heldElsewhere,
            turnError: error,
            subagentTurn: subagentTurn
        ))
    }

    private static let rateLimit = PushSessionError(type: "rate_limit", detail: "API Error: Rate limit reached")

    private static func finished(
        sound: String?,
        turnFailed: Bool = false,
        push: AttentionPushKind,
        followUp: Bool = true
    ) -> AttentionIntents {
        AttentionIntents(
            sound: sound,
            completion: .init(turnFailed: turnFailed),
            push: .init(kind: push),
            followUp: followUp ? .trackCompletion(turnFailed: turnFailed) : nil
        )
    }

    private static let finishedPush = AttentionPushKind.completion(isSubagent: false, interrupted: false)

    private static let hookRows: [IntentRow] = [
        IntentRow(
            rule: "a prompt rings the submit cue",
            moment: hook("UserPromptSubmit"),
            expected: AttentionIntents(sound: "UserPromptSubmit")
        ),
        IntentRow(
            rule: "a session start rings the start cue",
            moment: hook("SessionStart"),
            expected: AttentionIntents(sound: "SessionStart")
        ),
        IntentRow(
            rule: "a wire name is read as the island's own (Cursor's beforeSubmitPrompt)",
            moment: hook("beforeSubmitPrompt"),
            expected: AttentionIntents(sound: "UserPromptSubmit")
        ),
        IntentRow(
            rule: "a tool step offers its own cue, which has no sound",
            moment: hook("PreToolUse"),
            expected: AttentionIntents(sound: "PreToolUse")
        ),
        IntentRow(
            rule: "a single failed tool call stays silent",
            moment: hook("PostToolUseFailure"),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a hook event carrying the launch cue's name rings nothing: that cue is the app's own",
            moment: hook(SoundCue.launch),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a finished turn rings, pops its completion, pushes it and is followed up",
            moment: hook("Stop", endedTurn: true),
            expected: finished(sound: "Stop", push: finishedPush)
        ),
        IntentRow(
            rule: "a turn that died rings the error jingle and pushes the error, not a completion",
            moment: hook("StopFailure", endedTurn: true, error: rateLimit),
            expected: finished(sound: "StopFailure", turnFailed: true, push: .error)
        ),
        IntentRow(
            rule: "Grok's stop_failure is the same failed turn",
            moment: hook("stop_failure", endedTurn: true, error: rateLimit),
            expected: finished(sound: "StopFailure", turnFailed: true, push: .error)
        ),
        IntentRow(
            rule: "a failure while folded subagents still work: the jingle and the error push, no completion",
            moment: hook("StopFailure", error: rateLimit),
            expected: AttentionIntents(sound: "StopFailure", push: .init(kind: .error))
        ),
        IntentRow(
            rule: "a Stop while folded subagents still work rings, but completes nothing",
            moment: hook("Stop"),
            expected: AttentionIntents(sound: "Stop")
        ),
        IntentRow(
            rule: "an IDE's final response completes the turn (its own cue has no sound)",
            moment: hook("afterAgentResponse", endedTurn: true),
            expected: finished(sound: "AfterAgentResponse", push: finishedPush)
        ),
        IntentRow(
            rule: "a Cline task round completes the turn",
            moment: hook("TaskComplete", endedTurn: true),
            expected: finished(sound: "TaskRoundComplete", push: finishedPush)
        ),
        IntentRow(
            rule: "an Esc'd Stop pops its card without a chime, is offered to the push gate as interrupted, and is not followed up",
            moment: hook("Stop", endedTurn: true),
            subject: interrupted,
            expected: finished(sound: nil, push: .completion(isSubagent: false, interrupted: true), followUp: false)
        ),
        IntentRow(
            rule: "Cline's TaskCancel (an interrupted task round) pops its card without a chime",
            moment: hook("TaskCancel", endedTurn: true),
            subject: interrupted,
            expected: finished(sound: nil, push: .completion(isSubagent: false, interrupted: true), followUp: false)
        ),
        IntentRow(
            rule: "a Codex Interrupt: its card pops silently, the push gate turns it away",
            moment: hook("Interrupt", endedTurn: true),
            subject: interrupted,
            expected: finished(sound: nil, push: .completion(isSubagent: false, interrupted: true), followUp: false)
        ),
        IntentRow(
            rule: "only the turn's end goes silent: another event of an interrupted session still rings its cue",
            moment: hook("SessionStart"),
            subject: interrupted,
            expected: AttentionIntents(sound: "SessionStart")
        ),
        IntentRow(
            rule: "a subagent's turn end is offered to the push gate as a subagent's",
            moment: hook("Stop", endedTurn: true, subagentTurn: true),
            expected: finished(sound: "Stop", push: .completion(isSubagent: true, interrupted: false))
        ),
        IntentRow(
            rule: "an event filed under a subagent, dropped as stale or ending the session is silent",
            moment: hook("Stop", applied: false),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "SessionEnd is silent",
            moment: hook("SessionEnd", applied: false),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a subagent's failure filed under the session is not the session's error: nothing is pushed",
            moment: hook("StopFailure", applied: false, error: rateLimit),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "Copilot's errorOccurred pushes the error (its Notification cue has no sound)",
            moment: hook("errorOccurred", error: PushSessionError(type: "Error", detail: "boom")),
            expected: AttentionIntents(sound: "Notification", push: .init(kind: .error))
        ),
        // #378: a child's turns are its parent's business.
        IntentRow(
            rule: "a child's start is silent",
            moment: hook("SessionStart"),
            subject: child,
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a child's prompt is silent",
            moment: hook("UserPromptSubmit"),
            subject: child,
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a child's finished turn: no chime, no completion, no push, no follow-up",
            moment: hook("Stop", endedTurn: true),
            subject: child,
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a child's failed turn pushes nothing either",
            moment: hook("StopFailure", endedTurn: true, error: rateLimit),
            subject: child,
            expected: AttentionIntents()
        ),
        // #364: a conversation held somewhere else.
        IntentRow(
            rule: "a Hermes gateway chat's prompt is silent",
            moment: hook("pre_llm_call", heldElsewhere: true),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a Hermes gateway chat's turn end settles its card without a completion",
            moment: hook("on_session_end", endedTurn: true, heldElsewhere: true),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a Hermes turn at this Mac is a turn like any other",
            moment: hook("on_session_end", endedTurn: true),
            expected: finished(sound: "Stop", push: finishedPush)
        ),
    ]

    private static let requestRows: [IntentRow] = [
        IntentRow(
            rule: "the first approval of a burst chimes and pushes",
            moment: .approvalQueued(firstOfBurst: true),
            expected: AttentionIntents(sound: "PermissionRequest", push: .init(kind: .approval))
        ),
        IntentRow(
            rule: "a later approval of the burst only pushes",
            moment: .approvalQueued(firstOfBurst: false),
            expected: AttentionIntents(push: .init(kind: .approval))
        ),
        IntentRow(
            rule: "a child's approval still alerts: the user has to answer it",
            moment: .approvalQueued(firstOfBurst: true),
            subject: child,
            expected: AttentionIntents(sound: "PermissionRequest", push: .init(kind: .approval))
        ),
        IntentRow(
            rule: "the first question of a burst chimes and pushes",
            moment: .questionQueued(firstOfBurst: true),
            expected: AttentionIntents(sound: "PermissionRequest", push: .init(kind: .question))
        ),
        IntentRow(
            rule: "a later question only pushes",
            moment: .questionQueued(firstOfBurst: false),
            expected: AttentionIntents(push: .init(kind: .question))
        ),
        IntentRow(
            rule: "Codex Desktop's app-server question is never held back by Smart Suppress",
            moment: .questionQueued(firstOfBurst: true, smartSuppressible: false),
            expected: AttentionIntents(
                sound: "PermissionRequest",
                push: .init(kind: .question, smartSuppressible: false)
            )
        ),
        IntentRow(
            rule: "a child's question still alerts",
            moment: .questionQueued(firstOfBurst: true),
            subject: child,
            expected: AttentionIntents(sound: "PermissionRequest", push: .init(kind: .question))
        ),
        IntentRow(
            rule: "a request raised where the island cannot answer it chimes",
            moment: .requestRaisedElsewhere,
            expected: AttentionIntents(sound: "PermissionRequest")
        ),
        IntentRow(
            rule: "a child's request raised elsewhere still chimes",
            moment: .requestRaisedElsewhere,
            subject: child,
            expected: AttentionIntents(sound: "PermissionRequest")
        ),
        IntentRow(
            rule: "a live display-only wait pushes when it begins, and its reminders start over",
            moment: .displayOnlyWaitBegan(.approval, announce: true),
            expected: AttentionIntents(push: .init(kind: .displayOnlyWait), followUp: .restartWait(.approval))
        ),
        IntentRow(
            rule: "a rebuilt or backfilled wait only restarts its reminders",
            moment: .displayOnlyWaitBegan(.question, announce: false),
            expected: AttentionIntents(followUp: .restartWait(.question))
        ),
    ]

    private static let elsewhereTurnRows: [IntentRow] = [
        IntentRow(
            rule: "a turn in a new session rings the start cue",
            moment: .turnStarted(newSession: true),
            expected: AttentionIntents(sound: "SessionStart")
        ),
        IntentRow(
            rule: "a later turn rings the submit cue",
            moment: .turnStarted(newSession: false),
            expected: AttentionIntents(sound: "UserPromptSubmit")
        ),
        IntentRow(
            rule: "a child's turn starts silently",
            moment: .turnStarted(newSession: true),
            subject: child,
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "a finished Cowork turn rings, completes, pushes and is followed up",
            moment: .turnEnded(.completed, host: .claudeDesktop),
            expected: finished(sound: "Stop", push: finishedPush)
        ),
        IntentRow(
            rule: "a finished AiWork turn too",
            moment: .turnEnded(.completed, host: .aiwork),
            expected: finished(sound: "Stop", push: finishedPush)
        ),
        IntentRow(
            rule: "a failed Cowork turn rings the error jingle and pushes the error",
            moment: .turnEnded(.failed, host: .claudeDesktop),
            expected: finished(sound: "StopFailure", turnFailed: true, push: .error)
        ),
        IntentRow(
            rule: "a failed AiWork stream too",
            moment: .turnEnded(.failed, host: .aiwork),
            expected: finished(sound: "StopFailure", turnFailed: true, push: .error)
        ),
        IntentRow(
            rule: "Claude Desktop's Stop button: nothing at all, the card just reads interrupted",
            moment: .turnEnded(.stopped, host: .claudeDesktop),
            expected: AttentionIntents()
        ),
        IntentRow(
            rule: "an aborted AiWork stream pops its card, silently, with no push and no follow-up",
            moment: .turnEnded(.stopped, host: .aiwork),
            expected: AttentionIntents(completion: .init(turnFailed: false))
        ),
        IntentRow(
            rule: "a turn marked interrupted ends without a chime wherever it ran",
            moment: .turnEnded(.completed, host: .aiwork),
            subject: interrupted,
            expected: finished(sound: nil, push: .completion(isSubagent: false, interrupted: true), followUp: false)
        ),
        IntentRow(
            rule: "a child's turn end elsewhere is its parent's business too",
            moment: .turnEnded(.completed, host: .aiwork),
            subject: child,
            expected: AttentionIntents()
        ),
    ]

    private static let reminderRows: [IntentRow] = [
        IntentRow(
            rule: "an approval reminder rings the approval cue",
            moment: .reminderDue(.approval, turnFailed: false),
            expected: AttentionIntents(sound: "PermissionRequest")
        ),
        IntentRow(
            rule: "a question reminder rings the approval cue",
            moment: .reminderDue(.question, turnFailed: false),
            expected: AttentionIntents(sound: "PermissionRequest")
        ),
        IntentRow(
            rule: "a finished turn's reminder rings 'done' again",
            moment: .reminderDue(.completion, turnFailed: false),
            expected: AttentionIntents(sound: "Stop")
        ),
        IntentRow(
            rule: "a failed turn's reminder rings the error jingle again, not 'done'",
            moment: .reminderDue(.completion, turnFailed: true),
            expected: AttentionIntents(sound: "StopFailure")
        ),
        IntentRow(
            rule: "a launch rings the launch cue",
            moment: .appLaunched,
            expected: AttentionIntents(sound: "AppLaunch")
        ),
    ]

    func testWhatEachMomentCallsFor() {
        for row in Self.hookRows + Self.requestRows + Self.elsewhereTurnRows + Self.reminderRows {
            XCTAssertEqual(
                AttentionPolicy.intents(for: row.moment, subject: row.subject),
                row.expected,
                row.rule
            )
        }
    }

    // MARK: - What the settings and the room let through

    private struct SettleRow {
        let rule: String
        let intents: AttentionIntents
        var context = Context()
        let expected: AttentionDecision
    }

    /// The facts a context is built from, with everything on and the user
    /// nowhere near the session's terminal.
    private struct Context {
        var soundEnabled = true
        var audibleCues: Set<String> = ["SessionStart", "UserPromptSubmit", "Stop", "TaskRoundComplete", "StopFailure", "PermissionRequest", "AppLaunch"]
        var quietHours = false
        var muteWhenAway = true
        var sceneQuiet = false
        var completionStyle = CompletionStyle.expand
        var pushEnabled = true
        var sessionInFront = false

        func make() -> AttentionContext {
            let quietHours = quietHours, sceneQuiet = sceneQuiet, sessionInFront = sessionInFront
            return AttentionContext(
                sounds: SoundPreferences(enabled: soundEnabled, audibleCues: audibleCues),
                soundHold: SoundHold(quietHours: { quietHours }, muteWhenAway: muteWhenAway, sceneQuiet: { sceneQuiet }),
                completionStyle: completionStyle,
                pushEnabled: pushEnabled,
                sessionInFront: { sessionInFront }
            )
        }

        func with(_ change: (inout Context) -> Void) -> Context {
            var copy = self
            change(&copy)
            return copy
        }
    }

    private static let finishedTurn = AttentionIntents(
        sound: "Stop",
        completion: .init(turnFailed: false),
        push: .init(kind: .completion(isSubagent: false, interrupted: false)),
        followUp: .trackCompletion(turnFailed: false)
    )

    private static let settleRows: [SettleRow] = [
        // Sounds
        SettleRow(
            rule: "with everything on, the cue plays",
            intents: AttentionIntents(sound: "PermissionRequest"),
            expected: AttentionDecision(sound: "PermissionRequest")
        ),
        SettleRow(
            rule: "the master switch silences every cue",
            intents: AttentionIntents(sound: "PermissionRequest"),
            context: Context().with { $0.soundEnabled = false },
            expected: AttentionDecision()
        ),
        SettleRow(
            rule: "a cue whose own switch is off stays silent",
            intents: AttentionIntents(sound: "UserPromptSubmit"),
            context: Context().with { $0.audibleCues.remove("UserPromptSubmit") },
            expected: AttentionDecision()
        ),
        SettleRow(
            rule: "a cue with no sound of its own never plays",
            intents: AttentionIntents(sound: "PreToolUse"),
            expected: AttentionDecision()
        ),
        SettleRow(
            rule: "quiet hours hold every event sound back",
            intents: AttentionIntents(sound: "Stop"),
            context: Context().with { $0.quietHours = true },
            expected: AttentionDecision()
        ),
        SettleRow(
            rule: "a locked screen or a screen saver holds them back while 'mute when away' is on",
            intents: AttentionIntents(sound: "Stop"),
            context: Context().with { $0.sceneQuiet = true },
            expected: AttentionDecision()
        ),
        SettleRow(
            rule: "with 'mute when away' off, a locked screen still hears them",
            intents: AttentionIntents(sound: "Stop"),
            context: Context().with { $0.sceneQuiet = true; $0.muteWhenAway = false },
            expected: AttentionDecision(sound: "Stop")
        ),
        // Completions
        SettleRow(
            rule: "completion style expand pops the card",
            intents: AttentionIntents(completion: .init(turnFailed: false)),
            expected: AttentionDecision(completion: .init(turnFailed: false, presentation: .card))
        ),
        SettleRow(
            rule: "Smart Suppress is asked as the card shows (at once or from the queue), not when it is decided",
            intents: AttentionIntents(completion: .init(turnFailed: false)),
            context: Context().with { $0.sessionInFront = true },
            expected: AttentionDecision(completion: .init(turnFailed: false, presentation: .card))
        ),
        SettleRow(
            rule: "completion style glance lights the dot instead",
            intents: AttentionIntents(completion: .init(turnFailed: true)),
            context: Context().with { $0.completionStyle = .glance; $0.sessionInFront = true },
            expected: AttentionDecision(completion: .init(turnFailed: true, presentation: .glance))
        ),
        SettleRow(
            rule: "completion style off only updates the card (a failed turn still reads ERROR)",
            intents: AttentionIntents(completion: .init(turnFailed: true)),
            context: Context().with { $0.completionStyle = .off },
            expected: AttentionDecision(completion: .init(turnFailed: true, presentation: .statusOnly))
        ),
        // Pushes
        SettleRow(
            rule: "a push goes out when pushes are on",
            intents: AttentionIntents(push: .init(kind: .approval)),
            expected: AttentionDecision(push: .init(kind: .approval, smartSuppressed: false))
        ),
        SettleRow(
            rule: "with pushes off nothing is pushed",
            intents: AttentionIntents(push: .init(kind: .approval)),
            context: Context().with { $0.pushEnabled = false },
            expected: AttentionDecision()
        ),
        SettleRow(
            rule: "a push carries Smart Suppress's answer for the push gate",
            intents: AttentionIntents(push: .init(kind: .question)),
            context: Context().with { $0.sessionInFront = true },
            expected: AttentionDecision(push: .init(kind: .question, smartSuppressed: true))
        ),
        SettleRow(
            rule: "a push Smart Suppress may not hold back carries no such answer",
            intents: AttentionIntents(push: .init(kind: .question, smartSuppressible: false)),
            context: Context().with { $0.sessionInFront = true },
            expected: AttentionDecision(push: .init(kind: .question, smartSuppressed: false))
        ),
        // Follow-ups
        SettleRow(
            rule: "a finished turn is followed up while completions are announced",
            intents: AttentionIntents(followUp: .trackCompletion(turnFailed: false)),
            context: Context().with { $0.completionStyle = .glance },
            expected: AttentionDecision(followUp: .trackCompletion(turnFailed: false))
        ),
        SettleRow(
            rule: "follow-ups only chase completions the user asked to hear about",
            intents: AttentionIntents(followUp: .trackCompletion(turnFailed: false)),
            context: Context().with { $0.completionStyle = .off },
            expected: AttentionDecision()
        ),
        SettleRow(
            rule: "a display-only wait's reminders start over whatever the completion style",
            intents: AttentionIntents(followUp: .restartWait(.approval)),
            context: Context().with { $0.completionStyle = .off },
            expected: AttentionDecision(followUp: .restartWait(.approval))
        ),
        // All together
        SettleRow(
            rule: "a finished turn with everything on",
            intents: finishedTurn,
            expected: AttentionDecision(
                sound: "Stop",
                completion: .init(turnFailed: false, presentation: .card),
                push: .init(kind: .completion(isSubagent: false, interrupted: false), smartSuppressed: false),
                followUp: .trackCompletion(turnFailed: false)
            )
        ),
        SettleRow(
            rule: "a finished turn at a locked Mac with completions off: only the push is left",
            intents: finishedTurn,
            context: Context().with { $0.sceneQuiet = true; $0.completionStyle = .off },
            expected: AttentionDecision(
                completion: .init(turnFailed: false, presentation: .statusOnly),
                push: .init(kind: .completion(isSubagent: false, interrupted: false), smartSuppressed: false)
            )
        ),
    ]

    func testWhatTheSettingsAndTheRoomLetThrough() {
        for row in Self.settleRows {
            XCTAssertEqual(
                AttentionPolicy.settle(row.intents, context: row.context.make()),
                row.expected,
                row.rule
            )
        }
    }

    func testDecideSettlesWhatTheMomentCallsFor() {
        let context = Context().make()
        for row in Self.hookRows + Self.requestRows + Self.elsewhereTurnRows + Self.reminderRows {
            XCTAssertEqual(
                AttentionPolicy.decide(row.moment, subject: row.subject, context: context),
                AttentionPolicy.settle(row.expected, context: context),
                row.rule
            )
        }
    }

    // MARK: - The push gate's share

    /// Completions of subagents and of interrupted turns are offered to the
    /// push, so the push gate can say why it turned them away.
    func testThePushGateTurnsAwaySubagentAndInterruptedCompletions() {
        func gate(_ moment: AttentionMoment, _ subject: AttentionSubject = AttentionSubject()) -> PushSkipReason? {
            guard case .completion(let isSubagent, let interrupted)? = AttentionPolicy.intents(for: moment, subject: subject).push?.kind else {
                XCTFail("no completion push for \(moment)")
                return nil
            }
            return PushGate.evaluate(PushGateInput(
                kind: .completion,
                onlyWhenAway: false,
                idleThreshold: 300,
                presence: PushPresenceSnapshot(screenLocked: true),
                isSubagent: isSubagent,
                interrupted: interrupted
            ))
        }
        XCTAssertEqual(gate(Self.hook("Stop", endedTurn: true, subagentTurn: true)), .subagent)
        XCTAssertEqual(gate(Self.hook("Stop", endedTurn: true), Self.interrupted), .interrupted)
        XCTAssertNil(gate(Self.hook("Stop", endedTurn: true)))
    }

    // MARK: - Reading the room lazily

    /// Facts that cost something to read are read only when a decision
    /// depends on them — a tool step must not look up the frontmost app.
    func testCostlyFactsAreReadOnlyWhenADecisionNeedsThem() {
        var reads: [String] = []
        func context(soundEnabled: Bool = true, muteWhenAway: Bool = true, quietHours: Bool = false, pushEnabled: Bool = true) -> AttentionContext {
            AttentionContext(
                sounds: SoundPreferences(enabled: soundEnabled, audibleCues: ["Stop"]),
                soundHold: SoundHold(
                    quietHours: { reads.append("quietHours"); return quietHours },
                    muteWhenAway: muteWhenAway,
                    sceneQuiet: { reads.append("scene"); return false }
                ),
                completionStyle: .expand,
                pushEnabled: pushEnabled,
                sessionInFront: { reads.append("inFront"); return false }
            )
        }

        _ = AttentionPolicy.decide(Self.hook("PostToolUseFailure"), context: context())
        XCTAssertEqual(reads, [], "no cue, no card, no push: nothing to look up")

        reads = []
        _ = AttentionPolicy.decide(Self.hook("Stop"), context: context(soundEnabled: false))
        XCTAssertEqual(reads, [], "with the master switch off nothing holds a sound back")

        reads = []
        _ = AttentionPolicy.decide(Self.hook("PreToolUse"), context: context())
        XCTAssertEqual(reads, [], "a cue with no sound of its own reads neither the clock nor the lock state")

        reads = []
        _ = AttentionPolicy.decide(Self.hook("Stop"), context: context())
        XCTAssertEqual(reads, ["quietHours", "scene"], "a cue the user would hear asks what holds sounds back")

        reads = []
        _ = AttentionPolicy.decide(Self.hook("Stop"), context: context(muteWhenAway: false))
        XCTAssertEqual(reads, ["quietHours"], "the lock state is not read while 'mute when away' is off")

        reads = []
        _ = AttentionPolicy.decide(Self.hook("Stop"), context: context(quietHours: true))
        XCTAssertEqual(reads, ["quietHours"], "quiet hours already hold it")

        reads = []
        _ = AttentionPolicy.decide(Self.hook("Stop", endedTurn: true), context: context(pushEnabled: false))
        XCTAssertFalse(reads.contains("inFront"), "a card asks Smart Suppress as it shows, not when it is decided")

        reads = []
        _ = AttentionPolicy.decide(Self.hook("Stop", endedTurn: true), context: context())
        XCTAssertEqual(reads.filter { $0 == "inFront" }.count, 1, "the push asks once")

        reads = []
        _ = AttentionPolicy.decide(.approvalQueued(firstOfBurst: false), context: context(pushEnabled: false))
        XCTAssertEqual(reads, [], "no push, no Smart Suppress look-up")
    }

    // MARK: - Holding sounds back

    func testWhatHoldsSoundsBack() {
        func holds(quietHours: Bool = false, muteWhenAway: Bool = true, sceneQuiet: Bool = false) -> Bool {
            AttentionPolicy.holdsSounds(SoundHold(
                quietHours: { quietHours },
                muteWhenAway: muteWhenAway,
                sceneQuiet: { sceneQuiet }
            ))
        }
        XCTAssertFalse(holds())
        XCTAssertTrue(holds(quietHours: true))
        XCTAssertTrue(holds(quietHours: true, muteWhenAway: false))
        XCTAssertTrue(holds(sceneQuiet: true))
        XCTAssertFalse(holds(muteWhenAway: false, sceneQuiet: true))

        // A display that only went to sleep is not a quiet scene.
        var scene = SceneMuteState()
        scene.apply(.displaysSlept)
        XCTAssertFalse(holds(sceneQuiet: scene.isQuiet))
        scene.apply(.screenLocked)
        XCTAssertTrue(holds(sceneQuiet: scene.isQuiet))
    }

    // MARK: - Fixed rules, by name

    /// A hook-driven turn the user stopped (Claude Code, Hermes, Cline's
    /// TaskCancel) used to ring the "task complete" jingle.
    func testAnInterruptedHookTurnDoesNotRingDone() {
        let intents = AttentionPolicy.intents(
            for: .hookEvent(HookEventFacts(rawEventName: "Stop", appliedToSession: true, endedTurn: true)),
            subject: AttentionSubject(interrupted: true)
        )
        XCTAssertNil(intents.sound, "an interrupted turn ends without a chime")
        XCTAssertNotNil(intents.completion, "its card still pops")
    }

    /// A StopFailure filed under a subagent moved nothing on the parent's
    /// card, yet pushed an error under the parent's name.
    func testASubagentsFailureDoesNotPushAnErrorForItsParent() {
        let intents = AttentionPolicy.intents(for: .hookEvent(HookEventFacts(
            rawEventName: "StopFailure",
            appliedToSession: false,
            turnError: PushSessionError(type: "rate_limit", detail: "API Error")
        )))
        XCTAssertNil(intents.push)
    }

    func testSubjectIsReadOffTheSession() {
        XCTAssertEqual(AttentionSubject(nil), AttentionSubject())
        var session = SessionSnapshot()
        XCTAssertEqual(AttentionSubject(session), AttentionSubject())
        session.parentSessionId = "pi-parent"
        session.interrupted = true
        XCTAssertEqual(AttentionSubject(session), AttentionSubject(isChild: true, interrupted: true))
    }
}
