import Darwin
import Foundation

/// Which machine a hook request comes from — decided by the socket it
/// arrived on, never by what it says.
///
/// This Mac's hooks reach the main socket (``SocketPath``). A remote host's
/// reach a socket the island bound for that host alone, at the Mac's end of
/// the host's SSH forward. Whatever can reach a socket can write anything
/// into its payload, so a payload's `_remote_host_id`, `_remote_host_name`
/// and `_edge.host` are only a claim:
///
/// - On a host's socket, the island replaces them with that host's own id
///   and name (``stamp(_:id:name:)``). A request that forges another host,
///   or names none, is that host's all the same; the remote hook keeps
///   sending them for older islands, and they change nothing.
/// - The main socket gets no remote host's hooks, and no hook on this Mac
///   sends those fields. A request there that claims a remote host can only
///   be a local process passing itself off as one — out of reach of the
///   checks that keep a remote session from acting on this Mac, or under a
///   host it is not — and is refused (``claimsRemoteHost(_:)``).
public enum HookOrigin: Equatable, Sendable {
    /// This Mac: the main socket.
    case local
    /// The remote host with this id and name: the socket the island bound
    /// for it.
    case remoteHost(id: String, name: String)

    /// The payload keys that name the remote host a request came from.
    public static let hostIdKey = "_remote_host_id"
    public static let hostNameKey = "_remote_host_name"

    /// What becomes of a request (``admit(_:)``).
    public enum Admission {
        /// It goes on as `data`. `payload` is its parsed object when
        /// admitting it took a parse — always, on a host's socket — so the
        /// island need not parse it again.
        case admitted(Data, payload: [String: Any]?)
        /// The main socket got a request that claims a remote host.
        case refusedRemoteClaim
        /// A host's socket got something other than a JSON object: nothing
        /// can be stamped with the host, so nothing goes on.
        case refusedUnreadable
        /// The socket is a host's with a blank id: stamped with it, a
        /// request would name no host at all, and pass for this Mac's.
        case refusedBlankHost
    }

    /// Whether `id` names no host: empty, or nothing but whitespace — what
    /// every reader of `_remote_host_id` takes for this Mac.
    public static func isBlankHostId(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What becomes of a request that arrived on this origin's socket.
    /// Runs before HookIntake reads an edge's facts and before anything
    /// routes the request, so all of that sees the host the socket names.
    public func admit(_ data: Data) -> Admission {
        switch self {
        case .local:
            guard Self.mayClaimRemoteHost(data),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .admitted(data, payload: nil)
            }
            return Self.claimsRemoteHost(payload) ? .refusedRemoteClaim : .admitted(data, payload: payload)
        case .remoteHost(let id, let name):
            guard !Self.isBlankHostId(id) else { return .refusedBlankHost }
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .refusedUnreadable
            }
            let stamped = Self.stamp(payload, id: id, name: name)
            // Slashes unescaped, as the remote hook writes them: the island's
            // byte probes (`/.cursor/`) read paths as they are written.
            guard let bytes = try? JSONSerialization.data(
                withJSONObject: stamped,
                options: [.withoutEscapingSlashes]
            ) else {
                return .refusedUnreadable
            }
            return .admitted(bytes, payload: stamped)
        }
    }

    /// `payload` filed under the host `id` / `name`, whatever it claimed:
    /// its own `_remote_host_id` / `_remote_host_name` replaced, and the
    /// `host` of its `_edge` facts, which HookIntake reads, too.
    public static func stamp(_ payload: [String: Any], id: String, name: String) -> [String: Any] {
        var stamped = payload
        stamped[hostIdKey] = id
        stamped[hostNameKey] = name
        if var edge = stamped[HookEdgeFacts.key] as? [String: Any] {
            edge["host"] = ["id": id, "name": name]
            stamped[HookEdgeFacts.key] = edge
        }
        return stamped
    }

    /// Whether `payload` claims to come from a remote host: it names one
    /// (`_remote_host_id` or `_remote_host_name` anything but blank), or
    /// carries an edge's facts about the machine it runs on (`_edge.host`).
    public static func claimsRemoteHost(_ payload: [String: Any]) -> Bool {
        if names(payload[hostIdKey]) || names(payload[hostNameKey]) { return true }
        guard let edge = payload[HookEdgeFacts.key] as? [String: Any] else { return false }
        return edge["host"] != nil
    }

    /// A value that names something: anything but nothing, null or a blank
    /// string. A number is a name no remote edge sends, so it is a claim.
    private static func names(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        guard let string = value as? String else { return true }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let hostKeyBytes = Data("_remote_host".utf8)
    private static let unicodeEscapeBytes = Data(#"\u"#.utf8)

    /// Cheap probe on the raw bytes, so that a local hook — every one sends
    /// none of this — is not parsed one more time: whether the request may
    /// name a remote host. A key can hide from a byte search only behind a
    /// `\u` escape, or in UTF-16 or UTF-32, which JSONSerialization reads
    /// too and which put NUL bytes around every ASCII character (UTF-8 JSON
    /// has none).
    static func mayClaimRemoteHost(_ data: Data) -> Bool {
        data.range(of: hostKeyBytes) != nil
            || HookEdgeFacts.mayCarryFacts(data)
            || data.range(of: unicodeEscapeBytes) != nil
            || containsNUL(data)
    }

    private static func containsNUL(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return false }
            return memchr(base, 0, bytes.count) != nil
        }
    }
}
