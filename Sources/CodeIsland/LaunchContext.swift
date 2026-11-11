import AppKit
import Darwin

/// How this process came to be running. The boot jingle is a "yes, it
/// started" acknowledgement for someone who just double-clicked the app; for a
/// launch-at-login user it was a sound on every single login that nobody
/// asked for.
enum LaunchContext {
    /// How long after the GUI session began a launch still counts as "part of
    /// logging in". Login items on a busy Mac can take a minute or two to come
    /// up; a hand launch inside this window losing its jingle is harmless.
    static let loginWindow: TimeInterval = 180

    /// Pure decision. The Apple Event is the precise signal, but it is not
    /// always attached for `SMAppService` login items and is absent when the
    /// system relaunches apps it restores at login, so a session that began
    /// moments ago counts too. When the console login time is unknown, a
    /// just-booted machine (auto-login) is the fallback for the same question.
    nonisolated static func isLoginLaunch(
        launchedAsLoginItem: Bool,
        secondsSinceSessionStart: TimeInterval?,
        secondsSinceBoot: TimeInterval,
        window: TimeInterval = loginWindow
    ) -> Bool {
        if launchedAsLoginItem { return true }
        if let sinceSession = secondsSinceSessionStart {
            // A clock that moved backwards yields a negative age; treat it as
            // unknown rather than as "just logged in".
            return sinceSession >= 0 && sinceSession < window
        }
        return secondsSinceBoot < window
    }

    /// Whether loginwindow launched us as a login item. Only meaningful while
    /// the launch `oapp` Apple Event is still current, i.e. synchronously
    /// inside `applicationDidFinishLaunching`.
    @MainActor
    static func launchedAsLoginItemFromAppleEvent() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// When this user's GUI session began: the newest `console` login record
    /// in utmpx (what `who` prints). Public POSIX, no permission needed.
    nonisolated static func consoleSessionStart(user: String = NSUserName()) -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let record = getutxent() {
            let entry = record.pointee
            guard Int32(entry.ut_type) == USER_PROCESS,
                  fixedString(entry.ut_line) == "console",
                  fixedString(entry.ut_user) == user else { continue }
            let at = Date(timeIntervalSince1970: TimeInterval(entry.ut_tv.tv_sec)
                + TimeInterval(entry.ut_tv.tv_usec) / 1_000_000)
            if latest.map({ at > $0 }) ?? true { latest = at }
        }
        return latest
    }

    /// Gathers the inputs for `isLoginLaunch` at the current moment.
    @MainActor
    static func isCurrentLaunchAtLogin(now: Date = Date()) -> Bool {
        isLoginLaunch(
            launchedAsLoginItem: launchedAsLoginItemFromAppleEvent(),
            secondsSinceSessionStart: consoleSessionStart().map { now.timeIntervalSince($0) },
            secondsSinceBoot: ProcessInfo.processInfo.systemUptime
        )
    }

    /// utmpx string fields are fixed-size C char tuples, not always
    /// NUL-terminated when full.
    private nonisolated static func fixedString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
