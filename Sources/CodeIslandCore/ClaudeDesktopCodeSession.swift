import Foundation

/// Claude Code sessions run from Claude Desktop's Code tab.
///
/// Claude Desktop starts each Code-tab session's CLI with its own id for that
/// session in `CLAUDE_CODE_HOST_SESSION_ID` (`local_<uuid>`). The hook's
/// `session_id` is the CLI's id, which Claude Desktop's links do not accept, so
/// this host id is the only handle that reaches one specific session.
public enum ClaudeDesktopCodeSession {
    /// Environment variable Claude Desktop sets on a Code-tab session's CLI.
    public static let hostSessionEnvKey = "CLAUDE_CODE_HOST_SESSION_ID"

    /// Whether `id` has the shape Claude Desktop's URL handler accepts for
    /// `?session=` — `^local_[A-Za-z0-9-]{1,64}$` (verified in the shipped app
    /// bundle, v2.9939). Anything else is refused there, so it is dropped here.
    public static func isValidHostSessionId(_ id: String) -> Bool {
        let prefix = "local_"
        guard id.hasPrefix(prefix) else { return false }
        let body = id.dropFirst(prefix.count)
        guard (1...64).contains(body.count) else { return false }
        return body.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
        }
    }

    /// `claude://code/continue?session=<id>` — Claude Desktop routes this to
    /// that session's screen; its own Dock menu and Spotlight entries use the
    /// same link. Nil for anything that is not a well-formed host id, so a
    /// click never opens a guessed URL.
    public static func deepLinkURL(hostSessionId: String) -> URL? {
        guard isValidHostSessionId(hostSessionId) else { return nil }
        return URL(string: "claude://code/continue?session=\(hostSessionId)")
    }
}
