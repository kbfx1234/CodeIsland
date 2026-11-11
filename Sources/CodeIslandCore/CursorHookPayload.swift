import CryptoKit
import Foundation

/// A hook Cursor ran, whichever config it came from.
///
/// Cursor (the IDE, and cursor-agent) also runs the Claude Code hooks in
/// `~/.claude/settings.json`, `.claude/settings.json` and
/// `.claude/settings.local.json` — "Include third-party Plugins, Skills, and
/// other configs", on by default (cursor.com/docs/reference/third-party-hooks).
/// It turns each Claude event into its own step (PreToolUse → `preToolUse`,
/// UserPromptSubmit → `beforeSubmitPrompt`, Stop → `stop`, …; PermissionRequest
/// and Notification are not imported) and builds one input per step, which
/// every hook of that step gets: Cursor's camelCase `hook_event_name`,
/// `session_id` (its `conversation_id`), and `cursor_version` among its common
/// fields. CodeIsland's Claude Code hook carries no `--source`, and the process
/// tree never says Cursor (#220), so this payload is the only sign that Cursor,
/// not Claude Code, fired it (#377).
public enum CursorHookPayload {
    /// The source a Cursor payload declares when no `--source` came with it.
    /// `CLIProcessResolver.cliVariantOverride` still promotes it to
    /// `cursor-cli` under cursor-agent.
    public static let source = "cursor"

    /// Bridge field carrying ``deliveryDigest(of:)``.
    public static let digestKey = "_cursor_payload_digest"

    /// Cursor sets `cursor_version` on every hook input it builds. Claude Code
    /// and the other agents never send it.
    public static func isCursorHook(_ payload: [String: Any]) -> Bool {
        guard let version = payload["cursor_version"] as? String else { return false }
        return !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// SHA-256 of the payload exactly as Cursor wrote it to the hook's stdin.
    /// The hooks of one step read the same bytes, so a step that reaches both
    /// of CodeIsland's hooks (its own `~/.cursor/hooks.json` entry and the
    /// imported Claude Code one) yields one digest; what the bridge adds — the
    /// `cwd` Cursor runs each config's hooks in, `_ppid` — is not part of it.
    public static func deliveryDigest(of stdin: Data) -> String {
        SHA256.hash(data: stdin).map { String(format: "%02x", $0) }.joined()
    }
}

/// Lets one delivery of each Cursor hook event through.
///
/// A step CodeIsland is wired to in both configs (`beforeSubmitPrompt`,
/// `stop`) starts both hooks at once with one payload, so the island heard
/// every prompt and every finished turn twice: two chimes, a second
/// completion. Cursor only drops an imported hook whose command is the same
/// string as one of its own, and CodeIsland's two commands differ.
public struct CursorHookDeliveryFilter: Sendable {
    /// Both copies are spawned together; one arriving later than this is a
    /// new event that happens to carry the same payload.
    public let window: TimeInterval
    private var seen: [String: Date] = [:]

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    /// True when a delivery with `digest` already went through within `window`.
    public mutating func isRepeat(digest: String, now: Date) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        if seen[digest] != nil { return true }
        seen[digest] = now
        return false
    }
}
