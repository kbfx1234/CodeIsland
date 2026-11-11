import AppKit
import CodeIslandCore

/// Plays the 8-bit sound effects `AttentionPolicy` decides on, and supplies
/// it with the user's sound settings (`preferences`, `hold`).
@MainActor
class SoundManager {
    static let shared = SoundManager()

    private let defaults = UserDefaults.standard

    /// Map sound cues (event names, see `SoundCue`) to 8-bit WAV file names (without extension)
    static let eventSounds: [(event: String, sound: String, key: String, label: String)] = [
        ("SessionStart",      "8bit_start",    SettingsKey.soundSessionStart,   "会话开始"),
        ("TaskRoundComplete", "8bit_complete",  SettingsKey.soundTaskComplete,   "任务完成"),
        ("Stop",              "8bit_complete",  SettingsKey.soundTaskComplete,   "任务完成"),
        // A whole turn that died (API error, rate limit…) — not a single failed
        // tool call, which the agent recovers from on its own.
        (EventSoundRouting.turnFailed, "8bit_error", SettingsKey.soundTaskError, "任务错误"),
        ("PermissionRequest", "8bit_approval",  SettingsKey.soundApprovalNeeded, "需要审批"),
        ("UserPromptSubmit",  "8bit_submit",    SettingsKey.soundPromptSubmit,   "任务确认"),
    ]

    /// The launch chime: the app's own cue, with its own switch. It stays out
    /// of `eventSounds`, whose cues are hook event names (no hook event may
    /// carry this one, see `EventSoundRouting`), and is not preloaded.
    static let launchSound = (cue: SoundCue.launch, sound: "8bit_boot", key: SettingsKey.soundBoot)

    private var soundCache: [String: NSSound] = [:]

    /// A failing session tends to fail again seconds later (the user retries
    /// into the same rate limit); one error jingle per burst is the signal.
    private var turnFailureDebouncer = SoundDebouncer(window: 60)

    /// Where a *decided* event sound goes. Production plays it; a test installs
    /// a recorder and asserts on the names it receives.
    ///
    /// Only the play step is swappable — everything above it (the attention
    /// policy's master toggle, quiet hours and per-event toggle, and its "is
    /// this the start of a burst" rule) stays the code under test. That rule is
    /// not the same question as "should a card open", and it has already drifted
    /// once behind a shared `if` with nothing able to catch it. (#312)
    ///
    /// Deliberately not used by `preview` / `previewCustom`: those are direct UI
    /// actions, and folding them in here would make a recorder pick up button
    /// presses as if they were event sounds.
    var playSink: ((String) -> Void)?

    private func emit(_ soundName: String) {
        if let playSink {
            playSink(soundName)
            return
        }
        play(soundName)
    }

    private init() {
        // Pre-load all sounds into cache
        for entry in Self.eventSounds {
            if let sound = loadSound(entry.sound) {
                soundCache[entry.sound] = sound
            }
        }
    }

    /// A sound cue that has not been through `AttentionPolicy.settle`: the
    /// user's sound settings are applied here, by the policy's own rule
    /// (`AttentionPolicy.audibleSound`). `sessionId` scopes the turn-failure
    /// debounce; nil shares one bucket.
    func handleEvent(_ eventName: String, sessionId: String? = nil, now: Date = Date()) {
        guard let cue = AttentionPolicy.audibleSound(eventName, sounds: preferences, hold: hold) else { return }
        play(cue: cue, sessionId: sessionId, now: now)
    }

    /// A follow-up reminder's cue: the user's sound settings apply as to any
    /// cue, the turn-failure debounce does not. Reminders already come an
    /// interval apart, one per cue per tick; the debounce, there for a
    /// session failing again seconds later, would swallow another session's
    /// failed-turn reminder that happened to fall inside its window.
    func playReminder(_ cue: String) {
        guard let cue = AttentionPolicy.audibleSound(cue, sounds: preferences, hold: hold),
              let sound = Self.soundName(forCue: cue) else { return }
        emit(sound)
    }

    /// Plays a cue `AttentionPolicy` let through. All that is left to decide
    /// is the turn-failure jingle's debounce, which needs the jingles before it.
    func play(cue: String, sessionId: String? = nil, now: Date = Date()) {
        guard let sound = Self.soundName(forCue: cue) else { return }
        if cue == EventSoundRouting.turnFailed,
           !turnFailureDebouncer.shouldPlay(key: sessionId ?? "", now: now) {
            return
        }
        emit(sound)
    }

    /// The WAV a cue plays, nil for a cue with no sound of its own.
    private static func soundName(forCue cue: String) -> String? {
        if cue == launchSound.cue { return launchSound.sound }
        return eventSounds.first(where: { $0.event == cue })?.sound
    }

    /// Play boot sound on app launch: the policy's `.appLaunched` moment,
    /// settled like any other — master switch, its own switch, the hold.
    func playBoot() {
        let context = AttentionContext(
            sounds: preferences,
            soundHold: hold,
            // Only the sound settings matter for a launch.
            completionStyle: .off,
            pushEnabled: false,
            sessionInFront: { false }
        )
        guard let cue = AttentionPolicy.decide(.appLaunched, context: context).sound else { return }
        play(cue: cue)
    }

    // MARK: - Settings, for the policy

    /// The standing sound choices: the master switch, and every cue whose
    /// own switch is on. Read for every hook event, so with the master switch
    /// off (the default) the per-event switches are not read at all.
    var preferences: SoundPreferences {
        guard defaults.bool(forKey: SettingsKey.soundEnabled) else {
            return SoundPreferences(enabled: false, audibleCues: [])
        }
        var cues = Set(Self.eventSounds.filter { defaults.bool(forKey: $0.key) }.map(\.event))
        if defaults.bool(forKey: Self.launchSound.key) {
            cues.insert(Self.launchSound.cue)
        }
        return SoundPreferences(enabled: true, audibleCues: cues)
    }

    /// What may hold event sounds back right now. The clock and the lock
    /// state are read only for a cue the user would otherwise hear.
    var hold: SoundHold {
        SoundHold(
            quietHours: { self.quietHoursActive },
            muteWhenAway: muteWhenAway,
            sceneQuiet: { SceneMuteMonitor.shared.isQuietScene }
        )
    }

    /// Quiet-hours window test. Half-open [start, end) in minutes since
    /// midnight; start > end spans midnight; start == end never mutes (an
    /// all-day window would just be the master sound toggle).
    nonisolated static func isInQuietHours(minutesSinceMidnight m: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return m >= start && m < end }
        return m >= start || m < end
    }

    /// Whether event sounds are held back right now for a reason that will
    /// pass on its own — quiet hours, or nobody at the screen (locked, screen
    /// saver running). Distinct from the master toggle and the
    /// per-event toggles, which are standing choices: follow-up reminders
    /// wait out a deferral and catch up afterwards, but never a choice.
    /// Settings previews stay audible: only event-driven sounds are gated.
    var isEventSoundDeferred: Bool {
        AttentionPolicy.holdsSounds(hold)
    }

    /// Scene auto-mute, on unless the user turned it off. Read through
    /// `object(forKey:)` so an unregistered default still means "on".
    private var muteWhenAway: Bool {
        defaults.object(forKey: SettingsKey.autoMuteWhenAway) == nil
            ? SettingsDefaults.autoMuteWhenAway
            : defaults.bool(forKey: SettingsKey.autoMuteWhenAway)
    }

    private var quietHoursActive: Bool {
        guard defaults.bool(forKey: SettingsKey.quietHoursEnabled) else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Self.isInQuietHours(
            minutesSinceMidnight: (comps.hour ?? 0) * 60 + (comps.minute ?? 0),
            start: storedMinutes(SettingsKey.quietHoursStart, default: SettingsDefaults.quietHoursStart),
            end: storedMinutes(SettingsKey.quietHoursEnd, default: SettingsDefaults.quietHoursEnd)
        )
    }

    /// integer(forKey:) collapses "never set" to 0 (midnight) — fall back to
    /// the SettingsDefaults the UI shows instead.
    private func storedMinutes(_ key: String, default def: Int) -> Int {
        defaults.object(forKey: key) == nil ? def : defaults.integer(forKey: key)
    }

    /// Preview a specific sound (used by settings UI play buttons)
    func preview(_ soundName: String) {
        play(soundName)
    }

    /// Preview a custom sound file by path (used by settings UI)
    func previewCustom(_ path: String) {
        guard let sound = NSSound(contentsOfFile: path, byReference: false) else {
            NSSound.beep()
            return
        }
        if sound.isPlaying { sound.stop() }
        sound.volume = SoundVolumeCurve.amplitude(forPercent: defaults.integer(forKey: SettingsKey.soundVolume))
        sound.play()
    }

    /// Play a named 8-bit WAV with volume control, checking for custom sound first
    private func play(_ name: String) {
        let sound: NSSound? = loadCustomSound(name) ?? soundCache[name] ?? loadSound(name)
        guard let sound else {
            NSSound.beep()
            return
        }
        if sound.isPlaying { sound.stop() }
        sound.volume = SoundVolumeCurve.amplitude(forPercent: defaults.integer(forKey: SettingsKey.soundVolume))
        sound.play()
    }

    /// Load a custom sound from user-specified path
    private func loadCustomSound(_ name: String) -> NSSound? {
        guard let path = defaults.string(forKey: SettingsKey.soundCustomPath(name)),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return NSSound(contentsOfFile: path, byReference: false)
    }

    /// Load a WAV from the SPM resource bundle
    private func loadSound(_ name: String) -> NSSound? {
        // SPM generates Bundle.appModule for resource bundles
        // Resources are inside CodeIsland_CodeIsland.bundle/Resources/
        if let url = Bundle.appModule.url(forResource: name, withExtension: "wav", subdirectory: "Resources") {
            return NSSound(contentsOf: url, byReference: false)
        }
        // Fallback: try without subdirectory
        if let url = Bundle.appModule.url(forResource: name, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: false)
        }
        return nil
    }
}
