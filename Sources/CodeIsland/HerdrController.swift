import Foundation
import CodeIslandCore

struct HerdrRoutingIdentity: Equatable {
    let paneId: String
    let socketPath: String
    let binaryPath: String?
}

enum HerdrController {
    typealias Runner = (
        _ path: String,
        _ args: [String],
        _ env: [String: String],
        _ timeout: TimeInterval
    ) -> Data?

    /// Where Herdr is asked about this session — nil when it must not be.
    /// A remote session's pane belongs to the Herdr on its own host, so
    /// nothing here is ever run for it, whatever its hooks carried.
    static func identity(from session: SessionSnapshot) -> HerdrRoutingIdentity? {
        guard !session.isRemote, session.hasHerdrRoute else { return nil }
        let pane = session.herdrPaneId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The pane id goes to the binary as an argument; one that starts
        // like an option would be read as one.
        guard !pane.hasPrefix("-") else { return nil }
        let socket = session.herdrSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let binary = session.herdrBinaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HerdrRoutingIdentity(
            paneId: pane,
            socketPath: socket,
            binaryPath: binary?.isEmpty == false ? binary : nil
        )
    }

    static func shouldRoute(_ session: SessionSnapshot) -> Bool {
        !session.isRemote
            && session.hostHarness == nil
            && session.tmuxPane?.isEmpty != false
            && session.zellijPaneId?.isEmpty != false
            && identity(from: session) != nil
    }

    static func focus(
        _ identity: HerdrRoutingIdentity,
        runner: Runner = productionRunner
    ) -> Bool {
        guard let executable = executable(for: identity) else { return false }
        return runner(
            executable,
            ["agent", "focus", identity.paneId],
            ["HERDR_SOCKET_PATH": identity.socketPath],
            2
        ) != nil
    }

    static func isFocused(
        _ identity: HerdrRoutingIdentity,
        runner: Runner = productionRunner
    ) -> Bool {
        guard let executable = executable(for: identity),
              let data = runner(
                executable,
                ["agent", "get", identity.paneId],
                ["HERDR_SOCKET_PATH": identity.socketPath],
                1
              ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let agent = result["agent"] as? [String: Any] else {
            return false
        }
        return agent["focused"] as? Bool == true
    }

    /// The binary run for `identity`: the one the pane's env named, when that
    /// is a Herdr binary, else Herdr from a well-known location.
    static func executable(
        for identity: HerdrRoutingIdentity,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        if let captured = identity.binaryPath,
           isHerdrBinaryPath(captured),
           isExecutable(captured) {
            return captured
        }
        return [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            NSHomeDirectory() + "/.local/bin/herdr",
            "/usr/bin/herdr",
        ].first(where: isExecutable)
    }

    /// The captured path arrives in a hook payload (`_herdr_bin_path`) and is
    /// run on its own, every time Smart Suppress looks at the session — so it
    /// is trusted for where Herdr is installed, never for what it is: only an
    /// absolute path to a file called `herdr` is accepted.
    static func isHerdrBinaryPath(_ path: String) -> Bool {
        path.hasPrefix("/") && (path as NSString).lastPathComponent == "herdr"
    }

    private static func productionRunner(
        path: String,
        args: [String],
        env: [String: String],
        timeout: TimeInterval
    ) -> Data? {
        ProcessRunner.run(path: path, args: args, env: env, timeout: timeout)
    }
}
