import Foundation

/// Moments when nobody is at the screen: event sounds then only reach an empty
/// room, a meeting the laptop was carried into, or a sleeping household.
///
/// Three independent system states are tracked — screen locked, screen saver
/// running, displays asleep — because they overlap and end in any order (the
/// screen saver usually starts first and locks; the displays then sleep; wake
/// and unlock arrive later), and a single flag would be cleared by whichever
/// "end" arrived first.
///
/// Only a locked screen or a running screen saver makes the scene quiet. A
/// display that merely went to sleep is kept for the push "away" check, but
/// does not mute: its owner is often right there, waiting on the agent.
public struct SceneMuteState: Equatable, Sendable {
    public enum Signal: Equatable, Sendable {
        case screenLocked
        case screenUnlocked
        case screensaverStarted
        case screensaverStopped
        case displaysSlept
        case displaysWoke
    }

    public private(set) var screenLocked = false
    public private(set) var screensaverRunning = false
    public private(set) var displaysAsleep = false

    public init() {}

    public var isQuiet: Bool { screenLocked || screensaverRunning }

    /// Applies one system signal; returns whether `isQuiet` changed.
    @discardableResult
    public mutating func apply(_ signal: Signal) -> Bool {
        let wasQuiet = isQuiet
        switch signal {
        case .screenLocked:
            screenLocked = true
        case .screenUnlocked:
            // Unlocking takes a person at a lit, awake screen. Clearing the
            // other two here keeps a missed didstop / didWake notification
            // from muting the app until the next reboot.
            screenLocked = false
            screensaverRunning = false
            displaysAsleep = false
        case .screensaverStarted:
            screensaverRunning = true
        case .screensaverStopped:
            screensaverRunning = false
        case .displaysSlept:
            displaysAsleep = true
        case .displaysWoke:
            displaysAsleep = false
        }
        return wasQuiet != isQuiet
    }
}
