import Darwin
import Foundation
import SwiftUI
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

/// Whether the hook socket is up, and why not when it isn't.
///
/// Its default path is a predictable name in /tmp. When another user created
/// a file there first, the island can neither remove it (in a sticky folder
/// only its owner can) nor listen in its place, and hooks, which send only to
/// a socket this user owns (`SocketPath.Holder`), reach nothing. That must not
/// pass in silence: it is logged with the owner, shown in Settings → Hooks,
/// and tried again on the island's hook check, or from Settings.
@MainActor
final class HookSocketHealth: ObservableObject {
    static let shared = HookSocketHealth()

    enum Problem: Equatable {
        /// Another user owns what sits at `path`.
        case heldByOtherUser(path: String, uid: uid_t, userName: String?)
        /// The island cannot listen at `path` for another reason.
        case cannotListen(path: String)
    }

    /// Nil while the socket is up, or before the island first tried.
    @Published private(set) var problem: Problem?
    /// The server to try again, once one has failed to start.
    private weak var server: HookServer?
    private let lstat: (String) -> stat?

    /// `lstat` is for tests, which cannot create a file another user owns.
    init(lstat: @escaping (String) -> stat? = SocketPath.lstat) {
        self.lstat = lstat
    }

    /// Starts `server`; when it cannot, says why. True: it is listening.
    @discardableResult
    func start(_ server: HookServer) -> Bool {
        self.server = server
        if server.start() {
            problem = nil
            return true
        }
        let found = Self.diagnose(path: server.socketPath, lstat: lstat)
        if found != problem {
            switch found {
            case .heldByOtherUser(let path, let uid, let userName):
                log.error("Hook socket \(path, privacy: .public) belongs to another user, uid \(uid) (\(userName ?? "unknown", privacy: .public)): hooks send nothing to it, and nothing reaches CodeIsland until it is removed")
            case .cannotListen(let path):
                log.error("Hook socket \(path, privacy: .public) is unavailable: nothing reaches CodeIsland")
            }
        }
        problem = found
        return false
    }

    /// Tries the server again when it failed to start: the path may be free
    /// now. Nothing to do while it is listening.
    func retryIfDown() {
        guard problem != nil, let server else { return }
        start(server)
    }

    /// Why nothing could listen at `path`.
    nonisolated static func diagnose(
        path: String,
        uid: uid_t = getuid(),
        lstat: (String) -> stat? = SocketPath.lstat
    ) -> Problem {
        guard case .otherUser(let owner) = SocketPath.holder(of: path, uid: uid, lstat: lstat) else {
            return .cannotListen(path: path)
        }
        return .heldByOtherUser(path: path, uid: owner, userName: userName(of: owner))
    }

    /// The account name of `uid`, nil when it has none.
    nonisolated static func userName(of uid: uid_t) -> String? {
        var entry = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        return buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(uid, &entry, storage.baseAddress, storage.count, &found) == 0,
                  found != nil, let name = entry.pw_name else { return nil }
            return String(cString: name)
        }
    }

    /// Who owns the path, as Settings names them: "bob, uid 502".
    static func ownerDescription(uid: uid_t, userName: String?) -> String {
        userName.map { "\($0), uid \(uid)" } ?? "uid \(uid)"
    }
}

/// Settings → Hooks, while the hook socket is down: why, and a retry.
struct HookSocketProblemRow: View {
    let problem: HookSocketHealth.Problem
    let retry: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n["hook_socket_problem_title"])
                        .font(.system(size: 13, weight: .semibold))
                    Text(Self.detail(problem, l10n: l10n))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Button(l10n["hook_socket_retry"], action: retry)
        }
    }

    static func detail(_ problem: HookSocketHealth.Problem, l10n: L10n) -> String {
        switch problem {
        case .heldByOtherUser(let path, let uid, let userName):
            return String(
                format: l10n["hook_socket_taken_detail"],
                path,
                HookSocketHealth.ownerDescription(uid: uid, userName: userName)
            )
        case .cannotListen(let path):
            return String(format: l10n["hook_socket_unavailable_detail"], path)
        }
    }
}
