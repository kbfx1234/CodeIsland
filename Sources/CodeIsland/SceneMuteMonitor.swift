import AppKit
import CoreGraphics
import CodeIslandCore

/// Watches the system for "nobody is at the screen" moments — screen locked,
/// screen saver running, displays asleep — and feeds `SceneMuteState`.
///
/// Sources, all observable without any permission:
/// - `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` and
///   `com.apple.screensaver.didstart` / `didstop` on the distributed center
///   (posted by loginwindow / ScreenSaverEngine for any process to see).
///   Observed with `.deliverImmediately`: the island is an agent app that is
///   practically never active, and the default suspension behaviour holds and
///   coalesces distributed notifications for an inactive app;
/// - `NSWorkspace.screensDidSleep` / `screensDidWake`, and the login
///   session resigning / becoming active (fast user switching: another user
///   taking the console is this one leaving, coming back is an unlock);
/// - the login session's own lock flag (`CGSSessionScreenIsLocked`), read on
///   demand. It is the authority on "locked": a lock notification can still
///   go missing, and none comes at all when the app launches behind a lock.
///
/// Focus / Do Not Disturb and screen sharing are deliberately absent: neither
/// has a public API that works without an extra permission prompt or Full Disk
/// Access (see the follow-up notes in the feature report).
@MainActor
final class SceneMuteMonitor: NSObject {
    static let shared = SceneMuteMonitor()

    private var tracked = SceneMuteState()

    /// The session's lock flag: true when locked or when another user holds
    /// the console, nil when it cannot be read. Installed by `start()`; nil
    /// until then (tests drive the monitor with `apply` alone, or install a
    /// probe of their own).
    var lockProbe: (() -> Bool?)?

    /// Called on the main actor whenever the quiet scene begins or ends.
    /// Follow-up reminders use the "ended" edge to deliver what they held back.
    var onQuietChanged: ((_ isQuiet: Bool) -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var isStarted = false

    nonisolated static let distributedSignals: [String: SceneMuteState.Signal] = [
        "com.apple.screenIsLocked": .screenLocked,
        "com.apple.screenIsUnlocked": .screenUnlocked,
        "com.apple.screensaver.didstart": .screensaverStarted,
        "com.apple.screensaver.didstop": .screensaverStopped,
    ]

    nonisolated static let workspaceSignals: [(Notification.Name, SceneMuteState.Signal)] = [
        (NSWorkspace.screensDidSleepNotification, .displaysSlept),
        (NSWorkspace.screensDidWakeNotification, .displaysWoke),
        (NSWorkspace.sessionDidResignActiveNotification, .screenLocked),
        (NSWorkspace.sessionDidBecomeActiveNotification, .screenUnlocked),
    ]

    private override init() {
        super.init()
    }

    /// The current scene, with the lock taken from the session itself. A
    /// correction (a missed unlock, a launch behind the lock) is applied as
    /// the signal that went missing; its edge callback follows on the next
    /// main-actor turn.
    var state: SceneMuteState {
        reconcileLock()
        return tracked
    }

    var isQuietScene: Bool { state.isQuiet }

    /// Begin observing. Idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        if lockProbe == nil { lockProbe = Self.systemScreenLocked }

        let distributed = DistributedNotificationCenter.default()
        for name in Self.distributedSignals.keys {
            distributed.addObserver(
                self,
                selector: #selector(distributedSignal(_:)),
                name: Notification.Name(name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, signal) in Self.workspaceSignals {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(signal) }
            }
            workspaceObservers.append(token)
        }
        // Launched behind the lock screen: no lock notification is coming.
        reconcileLock()
    }

    /// Applies one signal. Internal so tests can drive the monitor directly.
    func apply(_ signal: SceneMuteState.Signal) {
        guard tracked.apply(signal) else { return }
        onQuietChanged?(tracked.isQuiet)
    }

    /// Test hook: forget every signal seen so far, and any lock probe.
    func resetForTesting() {
        tracked = SceneMuteState()
        lockProbe = nil
    }

    /// Reads `CGSSessionScreenIsLocked` (and whether this session owns the
    /// console) from the current login session.
    nonisolated static func systemScreenLocked() -> Bool? {
        screenLocked(fromSession: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// Locked, or not on the console (fast user switching); nil when the
    /// session dictionary is unavailable (no window server).
    nonisolated static func screenLocked(fromSession session: [String: Any]?) -> Bool? {
        guard let session else { return nil }
        let locked = (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        let onConsole = (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? true
        return locked || !onConsole
    }

    private func reconcileLock() {
        guard let locked = lockProbe?(), locked != tracked.screenLocked,
              tracked.apply(locked ? .screenLocked : .screenUnlocked) else { return }
        // This runs inside whoever is reading the state — a push decision, a
        // sound, a follow-up tick — so the edge the missed signal owed is
        // announced on the next turn, never re-entrantly into that reader.
        let isQuiet = tracked.isQuiet
        Task { @MainActor [weak self] in
            guard let self, self.tracked.isQuiet == isQuiet else { return }
            self.onQuietChanged?(isQuiet)
        }
    }

    /// Delivered on the main thread, where the observer was registered.
    @objc private nonisolated func distributedSignal(_ note: Notification) {
        guard let signal = Self.distributedSignals[note.name.rawValue] else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.apply(signal) }
        } else {
            Task { @MainActor in self.apply(signal) }
        }
    }
}
