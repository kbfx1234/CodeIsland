import Foundation

/// Grok Build's per-session store:
/// `$GROK_HOME/sessions/<percent-encoded cwd>/<session id>/chat_history.jsonl`
/// (next to `summary.json` and `updates.jsonl`). Shared by the hook bridge and
/// the app so both derive the same paths.
public enum GrokSessionPaths {
    /// Grok percent-encodes the full cwd into a single directory component,
    /// including `/` as `%2F` (for example `/Users/me` -> `%2FUsers%2Fme`).
    public static func encodedCwd(_ cwd: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    public static func chatHistoryPath(grokHome: String, cwd: String, sessionId: String) -> String? {
        guard !sessionId.isEmpty,
              !sessionId.contains("/"),
              let encodedCwd = encodedCwd(cwd) else { return nil }
        return "\(grokHome)/sessions/\(encodedCwd)/\(sessionId)/chat_history.jsonl"
    }

    /// Grok hooks carry no transcript path, so the bridge derives one. It is
    /// only handed on once the file exists: a new session writes it lazily,
    /// sessions known only to Grok's search index have none, and a path that
    /// does not exist yet would pin the tailer to nothing for that session.
    public static func existingChatHistoryPath(
        grokHome: String,
        cwd: String,
        sessionId: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard let path = chatHistoryPath(grokHome: grokHome, cwd: cwd, sessionId: sessionId),
              fileExists(path) else { return nil }
        return path
    }
}
