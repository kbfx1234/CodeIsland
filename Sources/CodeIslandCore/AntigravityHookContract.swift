import Foundation

/// How CodeIsland answers Google Antigravity's (`agy`) `PreToolUse` hook (#339).
///
/// Antigravity runs `PreToolUse` synchronously before every tool call and reads a
/// decision from stdout (https://antigravity.google/docs/hooks):
/// `allow | deny | ask | force_ask | deny_unless_prior_grant`. In practice the
/// hook is a restriction layer only — `deny` is honoured, but `allow` never
/// satisfies Antigravity's own permission check, so an ungranted call still
/// raises the native prompt (google-antigravity/antigravity-cli#1053, #1059).
/// And the gate fails closed: empty stdout, `{}`, a non-zero exit or a timeout
/// all refuse the tool call (manaflow-ai/cmux#5358).
///
/// Holding the hook open for an island card therefore added a second approval
/// in front of every tool call — including reads Antigravity runs silently —
/// whose Allow button could not approve anything. The island now only
/// observes: it answers `ask` straight away, which hands the call back to
/// Antigravity's own permission engine (grants, presets and "Always Allow"
/// still apply), and shows the tool as running.
///
/// `ask` rather than `allow` on purpose: `allow` is documented as
/// "automatically allows the tool execution", so the day Antigravity starts
/// honouring it an observer that says `allow` would silently switch off every
/// native prompt the user relies on.
public enum AntigravityHookContract {
    /// `PreToolUse` stdout that leaves the decision to Antigravity itself.
    public static let deferToNativePermission = #"{"decision":"ask"}"#

    /// Sources whose `PreToolUse` comes from Antigravity. Gemini CLI never emits
    /// `PreToolUse` (its approval hook is `BeforeTool`), so a Gemini-tagged
    /// `PreToolUse` is `agy` reading hooks wired with `--source gemini` (#233).
    public static func isAntigravityPreToolUse(source: String?, eventName: String?) -> Bool {
        guard let eventName, EventNormalizer.normalize(eventName) == "PreToolUse" else { return false }
        switch SessionSnapshot.normalizedSupportedSource(source) {
        case "google-antigravity", "gemini":
            return true
        default:
            return false
        }
    }

    /// What the bridge must print for this hook invocation before anything
    /// else can exit it, or nil when the invocation owes Antigravity nothing.
    public static func hookStdout(source: String?, eventName: String?) -> String? {
        isAntigravityPreToolUse(source: source, eventName: eventName) ? deferToNativePermission : nil
    }
}
