import Foundation
import CodeIslandCore

enum KiroAccountUsageClient {
    /// One ACP request after initialization, without opening an agent session.
    /// The replies are handled on a serial queue. The semaphore publishes the
    /// result to the caller, which waits off the main actor.
    private final class Reply: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private(set) var snapshot: KiroAccountUsageSnapshot?
        private var finished = false

        func finish(_ snapshot: KiroAccountUsageSnapshot? = nil) {
            guard !finished else { return }
            finished = true
            self.snapshot = snapshot
            ready.signal()
        }
    }

    static func fetch() -> KiroAccountUsageSnapshot? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init)
            + [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        guard let executable = directories.filter({ $0.hasPrefix("/") }).map({ $0 + "/kiro-cli" })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        return fetch(executable: URL(fileURLWithPath: executable))
    }

    static func fetch(executable: URL, timeout: TimeInterval = 8) -> KiroAccountUsageSnapshot? {
        let reply = Reply()
        let client = CodexAppServerClient(
            executableURL: executable, arguments: ["acp", "--agent-engine=v3", "--auth-method=cli"],
            callbackQueue: DispatchQueue(label: "com.codeisland.kiro-usage")
        )
        client.onExit = { _ in reply.finish() }
        client.onMessage = { [weak client] message in
            switch message.kind {
            case .response(id: .int(1)):
                if (try? client?.sendRequest(method: "_kiro/account/getUsage", params: [String: String]())) == nil {
                    reply.finish()
                }
            case .response(id: .int(2)):
                reply.finish(KiroAccountUsageParser.parseACPResult(message.raw["result"]))
            case .error(id: .int(1), code: _, message: _), .error(id: .int(2), code: _, message: _):
                reply.finish()
            default:
                break
            }
        }
        defer { client.stop() }
        let info = ["name": "codeisland", "version": AppVersion.current]
        do {
            try client.start()
            try client.sendRequest(method: "initialize", params: [
                "protocolVersion": 2, "info": info, "clientInfo": info,
                "capabilities": [String: String](), "clientCapabilities": [String: String](),
            ])
        } catch {
            return nil
        }
        return reply.ready.wait(timeout: .now() + timeout) == .success ? reply.snapshot : nil
    }
}
