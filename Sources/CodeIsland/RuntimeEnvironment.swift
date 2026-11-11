import Foundation

/// Facts about the process this code is running in.
enum RuntimeEnvironment {
    /// True inside an XCTest run (`swift test`, Xcode).
    ///
    /// Code that would act on the machine the tests run on — scripting the
    /// user's terminal, reading which app is in front, rewriting
    /// `~/.codeisland/sessions.json` — checks this to pick an inert default,
    /// so a test only reaches real state when it asks for it explicitly.
    /// Xcode's runner sets `XCTestConfigurationFilePath`; `swift test` does
    /// not, but its `xctest` host has XCTest loaded, which the app never links.
    static let isRunningTests: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()

    /// True when launched with `CODEISLAND_ISOLATED=1`: a development build or
    /// a launch smoke test running next to the installed app, which must leave
    /// this Mac's agents alone. It installs and repairs no hooks, discovers no
    /// sessions, watches no process (not even one a hook names, so it never
    /// signals one as an orphan), connects no remote host, checks for no update or
    /// plan limits, keeps its sessions in a folder of its own, and hears hooks
    /// only on its own `CODEISLAND_SOCKET_PATH` (without one it quits).
    static let isIsolated = isIsolated(ProcessInfo.processInfo.environment)

    static func isIsolated(_ environment: [String: String]) -> Bool {
        environment["CODEISLAND_ISOLATED"] == "1"
    }

    /// Why an isolated launch can't go on, or nil. Without a socket of its
    /// own it would answer every hook on this Mac in place of the real app.
    static func isolationProblem(_ environment: [String: String]) -> String? {
        guard isIsolated(environment) else { return nil }
        let socket = environment["CODEISLAND_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return socket.isEmpty ? "CODEISLAND_ISOLATED=1 needs CODEISLAND_SOCKET_PATH" : nil
    }
}
