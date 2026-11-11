import XCTest
@testable import CodeIslandCore

/// A remote host's hook describes a session on that host. Its `_ppid` names
/// a process there, so it never becomes `cliPid` — the process the island
/// watches here and, once orphaned, SIGTERMs — and the card is marked remote
/// whichever hook created it.
final class RemoteHookLocalFieldsTests: XCTestCase {
    private func hook(_ name: String, _ fields: [String: Any] = [:]) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": "s1",
            "cwd": "/home/me/project",
            "_source": "codex",
            "_ppid": 4242,
        ]
        payload.merge(fields) { _, new in new }
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private let remote: [String: Any] = ["_remote_host_id": "devbox", "_remote_host_name": "Dev Box"]
    private let subagent: [String: Any] = ["agent_id": "sub-1", "agent_type": "worker", "tool_name": "Bash"]

    func testRemoteHookNeverSetsCliPid() throws {
        let hooks: [(String, [String: Any])] = [
            ("SessionStart", remote),
            ("PreToolUse", remote.merging(["tool_name": "Bash"]) { _, new in new }),
            ("PreToolUse", remote.merging(subagent) { _, new in new }),
        ]
        for (name, fields) in hooks {
            let event = try hook(name, fields)
            var sessions: [String: SessionSnapshot] = [:]
            let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)
            let cardId = try XCTUnwrap(event.sessionId)
            let card = try XCTUnwrap(sessions[cardId], "\(name) \(fields)")

            XCTAssertNil(card.cliPid, "\(name) \(fields)")
            XCTAssertNil(card.cliStartTime, "\(name) \(fields)")
            XCTAssertEqual(card.remotePid, 4242, "\(name) \(fields)")
            XCTAssertFalse(effects.contains(.tryMonitorSession(sessionId: cardId)), "\(name) \(fields)")
        }
    }

    /// A subagent's hook only fills gaps on its parent's card, and the host
    /// was not one of them: a card a remote subagent's hook created looked
    /// local, so the island watched the remote pid here, tailed the remote
    /// transcript path here and offered to jump into this Mac's terminals.
    func testCardCreatedByARemoteSubagentHookIsRemote() throws {
        let event = try hook("PreToolUse", remote.merging(subagent) { _, new in new })
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        let card = try XCTUnwrap(sessions["remote:devbox:s1"])
        XCTAssertTrue(card.isRemote)
        XCTAssertEqual(card.remoteHostId, "devbox")
        XCTAssertEqual(card.remoteHostName, "Dev Box")
    }

    func testLocalHookStillSetsCliPid() throws {
        for fields in [[:], subagent] {
            let event = try hook("PreToolUse", fields.merging(["tool_name": "Bash"]) { old, _ in old })
            var sessions: [String: SessionSnapshot] = [:]
            let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

            XCTAssertEqual(sessions["s1"]?.cliPid, 4242, "\(fields)")
            XCTAssertNil(sessions["s1"]?.remotePid, "\(fields)")
            if fields.isEmpty {
                XCTAssertTrue(effects.contains(.tryMonitorSession(sessionId: "s1")))
            }
        }
    }

    /// The host's own process ids still tell its sessions apart: a remote
    /// Codex thread running in the same process as its parent is guessed to
    /// be that parent's — on that host only.
    func testRemotePidIsComparedOnlyWithItsOwnHostsHooks() throws {
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: try hook("UserPromptSubmit", remote), maxHistory: 10)
        sessions["remote:devbox:s1"]?.status = .running

        XCTAssertEqual(
            SubsessionCards.samePidCard(source: "codex", ppid: 4242, remoteHostId: "devbox", in: sessions),
            "remote:devbox:s1"
        )
        XCTAssertNil(SubsessionCards.samePidCard(source: "codex", ppid: 4242, remoteHostId: nil, in: sessions),
                     "a local hook's 4242 is another process")
        XCTAssertNil(SubsessionCards.samePidCard(source: "codex", ppid: 4242, remoteHostId: "other", in: sessions))

        var card = try XCTUnwrap(sessions["remote:devbox:s1"])
        XCTAssertEqual(card.processId(onHost: "devbox"), 4242)
        XCTAssertNil(card.processId(onHost: nil))
        card.remoteHostId = nil
        card.cliPid = 77
        XCTAssertEqual(card.processId(onHost: nil), 77)
        XCTAssertNil(card.processId(onHost: "devbox"))
    }
}
