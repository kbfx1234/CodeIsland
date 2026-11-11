import XCTest
@testable import CodeIslandCore

/// The parent of a Codex subagent thread, and the per-thread rollout cache
/// that lets every Codex hook ask for it.
final class CodexThreadSubsessionTests: XCTestCase {
    private let rollout = "/rollouts/child.jsonl"
    private let metadata = CodexSubagentMetadata(parentThreadId: "parent-thread", agentType: "worker", agentNickname: "Ohm")

    private func hook(_ extra: [String: Any] = [:]) -> [String: Any] {
        [
            "hook_event_name": "PreToolUse", "session_id": "child-thread", "_source": "codex",
            "transcript_path": rollout, "_ppid": 7070,
        ].merging(extra) { _, new in new }
    }

    // MARK: - The link

    func testRolloutNamesTheParentInItsOwnNamespace() throws {
        var desktopParent = subsessionCard(source: "codex", providerSessionId: "parent-thread", termBundleId: "com.openai.codex")
        desktopParent.status = .running
        let context = StubSubsessionContext(
            cards: [
                "codexapp:parent-thread": desktopParent,
                "parent-thread": subsessionCard(source: "codex", providerSessionId: "parent-thread"),
            ],
            rollouts: [rollout: .subagent(metadata)]
        )
        let cli = try XCTUnwrap(CodexThreadSubsession.link(in: hook(), context: context))
        XCTAssertEqual(cli.parentCardId, "parent-thread")
        XCTAssertEqual(cli.agentId, "child-thread")
        XCTAssertEqual(cli.agentType, "worker")
        XCTAssertFalse(cli.isInferred)

        let desktop = try XCTUnwrap(CodexThreadSubsession.link(in: hook(["_term_bundle": "com.openai.codex"]), context: context))
        XCTAssertEqual(desktop.childCardId, "codexapp:child-thread")
        XCTAssertEqual(desktop.parentCardId, "codexapp:parent-thread")
        XCTAssertEqual(context.rolloutQueries, [rollout, rollout])
    }

    func testRootRolloutIsTheLastWordOverASharedProcess() {
        // Another thread of the same app-server process is busy: before the
        // rollout is readable that is a guess at a parent; once it says root,
        // the thread is nobody's child.
        let context = StubSubsessionContext(cards: [
            "sibling": subsessionCard(source: "codex", status: .running, cliPid: 7070),
        ])
        XCTAssertEqual(CodexThreadSubsession.link(in: hook(), context: context)?.isInferred, true)
        context.rollouts[rollout] = .root
        XCTAssertNil(CodexThreadSubsession.link(in: hook(), context: context))
    }

    func testSharedProcessGuessNeedsAnActiveParentUnlessTheThreadNamesItself() {
        let context = StubSubsessionContext(cards: [
            "idle-thread": subsessionCard(source: "codex", status: .idle, cliPid: 7070),
        ])
        XCTAssertNil(CodexThreadSubsession.link(in: hook(), context: context), "an idle process's next thread is not a child")
        let named = CodexThreadSubsession.link(in: hook(["agent_id": "child-thread"]), context: context)
        XCTAssertEqual(named?.parentCardId, "idle-thread")
        XCTAssertEqual(named?.isProviderFolded, false, "a thread naming itself is still filed under its own id")
    }

    func testDesktopThreadsAreNeverGuessedFromTheSharedAppServer() {
        var sibling = subsessionCard(source: "codex", status: .running, cliPid: 7070)
        sibling.termBundleId = "com.openai.codex"
        let context = StubSubsessionContext(cards: ["codexapp:sibling": sibling])
        XCTAssertNil(CodexThreadSubsession.link(in: hook(["_term_bundle": "com.openai.codex"]), context: context))
    }

    func testThreadCodexFiledUnderItsParentNeedsNoRollout() throws {
        let context = StubSubsessionContext()
        let link = try XCTUnwrap(CodexThreadSubsession.link(
            in: hook(["session_id": "root-thread", "agent_id": "child-thread", "agent_type": "worker"]),
            context: context
        ))
        XCTAssertTrue(link.isProviderFolded)
        XCTAssertEqual(link.parentCardId, "root-thread")
        XCTAssertEqual(link.agentId, "child-thread")
        XCTAssertTrue(context.rolloutQueries.isEmpty)
    }

    func testRolloutOfAThreadFiledUnderItsParentWithoutAnAgentId() throws {
        // Codex filed the hook under the root's id with no `agent_id`, yet it
        // ran in a subagent: it already sits on the root's card, but as the
        // root's own event, so the thread's Stop would end the root's turn.
        // In every mode it goes by the thread's own id there. Never a link
        // from the root's card to itself, which would silence it.
        let named = CodexSubagentMetadata(
            parentThreadId: "parent-thread", agentType: "worker", agentNickname: "Ohm", threadId: "child-thread"
        )
        let context = StubSubsessionContext(
            cards: ["parent-thread": subsessionCard(source: "codex", providerSessionId: "parent-thread")],
            rollouts: [rollout: .subagent(named)]
        )
        let filed = hook(["session_id": "parent-thread"])
        let link = try XCTUnwrap(CodexThreadSubsession.link(in: filed, context: context))
        XCTAssertTrue(link.isProviderFolded)
        XCTAssertTrue(link.isFiledAsParentsOwn)
        XCTAssertEqual(link.agentId, "child-thread", "the rollout's own thread")
        XCTAssertEqual(link.parentCardId, "parent-thread")

        func placement(_ mode: SubsessionMode, blocking: Bool = false) -> SubsessionPlacement {
            SubsessionRouter.placement(for: link, mode: mode, cards: context.cards, isBlockingRequest: { blocking })
        }
        XCTAssertEqual(placement(.separate), .fold(into: "parent-thread"))
        XCTAssertEqual(placement(.merge), .fold(into: "parent-thread"))
        XCTAssertEqual(placement(.hide), .hidden)
        XCTAssertEqual(placement(.hide, blocking: true), .fold(into: "parent-thread"), "a request still reaches the user")

        for mode in [SubsessionMode.separate, .merge] {
            var raw = filed
            XCTAssertEqual(
                SubsessionRouter.route(&raw, link: link, mode: mode, cards: context.cards, isBlockingRequest: { false }),
                .rewritten
            )
            XCTAssertEqual(raw["session_id"] as? String, "parent-thread", "\(mode)")
            XCTAssertEqual(raw["agent_id"] as? String, "child-thread", "\(mode)")
            XCTAssertEqual(raw["agent_type"] as? String, "worker", "\(mode)")
            XCTAssertNil(SubsessionRouter.parentCardId(in: raw), "\(mode)")
        }

        // A rollout that names no thread: the hook still goes by an id of
        // its own on the card, never as the root's own event.
        context.rollouts[rollout] = .subagent(metadata)
        let unnamed = try XCTUnwrap(CodexThreadSubsession.link(in: filed, context: context))
        XCTAssertEqual(unnamed.agentId, "parent-thread")
        XCTAssertEqual(
            SubsessionRouter.placement(for: unnamed, mode: .merge, cards: context.cards, isBlockingRequest: { false }),
            .fold(into: "parent-thread")
        )
    }

    func testThreadFiledUnderAParentWithNoCardYetIsStillNamed() throws {
        // The rollout names the session the hook is filed under as the
        // thread's parent: the hook is the thread's even before that card
        // exists, whatever else shares the process.
        let named = CodexSubagentMetadata(
            parentThreadId: "parent-thread", agentType: "worker", agentNickname: nil, threadId: "child-thread"
        )
        let context = StubSubsessionContext(
            cards: ["busy-sibling": subsessionCard(source: "codex", status: .running, cliPid: 7070)],
            rollouts: [rollout: .subagent(named)]
        )
        let link = try XCTUnwrap(CodexThreadSubsession.link(in: hook(["session_id": "parent-thread"]), context: context))
        XCTAssertTrue(link.isFiledAsParentsOwn)
        XCTAssertEqual(link.parentCardId, "parent-thread")
        XCTAssertEqual(link.agentId, "child-thread")
    }

    func testRemoteThreadsRolloutIsNeverReadHere() {
        let context = StubSubsessionContext(rollouts: [rollout: .subagent(metadata)])
        XCTAssertNil(CodexThreadSubsession.link(in: hook(["_remote_host_id": "devbox"]), context: context))
        XCTAssertTrue(context.rolloutQueries.isEmpty)
    }

    func testPluginProxyIsNotACodexThread() {
        let context = StubSubsessionContext(rollouts: [rollout: .subagent(metadata)])
        XCTAssertNil(CodexThreadSubsession.link(in: hook(["_via_plugin": true]), context: context))
    }

    // MARK: - Reading each rollout once

    private final class Reads {
        var paths: [String] = []
    }

    func testRolloutIsReadOnce() {
        let reads = Reads()
        let cache = CodexRolloutCache { path in
            reads.paths.append(path)
            return path.hasSuffix("root.jsonl") ? .root : .subagent(self.metadata)
        }
        for _ in 0..<5 {
            XCTAssertEqual(cache.inspection(transcriptPath: "/r/child.jsonl").metadata, metadata)
            XCTAssertEqual(cache.inspection(transcriptPath: "/r/root.jsonl"), .root)
        }
        XCTAssertEqual(reads.paths, ["/r/child.jsonl", "/r/root.jsonl"])
    }

    /// The answer is the file's. Codex has filed a subagent's hooks under its
    /// parent's session id, naming the subagent's rollout: that never makes
    /// the parent's own rollout read as a subagent's, or the other way round.
    func testEachRolloutKeepsItsOwnAnswer() {
        let reads = Reads()
        let cache = CodexRolloutCache { path in
            reads.paths.append(path)
            return path == "/r/child.jsonl" ? .subagent(self.metadata) : .root
        }
        XCTAssertEqual(cache.inspection(transcriptPath: "/r/child.jsonl").metadata, metadata)
        XCTAssertEqual(cache.inspection(transcriptPath: "/r/parent.jsonl"), .root)
        XCTAssertEqual(cache.inspection(transcriptPath: "/r/child.jsonl").metadata, metadata)
        XCTAssertEqual(reads.paths, ["/r/child.jsonl", "/r/parent.jsonl"])
    }

    func testUnreadableRolloutIsTriedOnAScheduleThenLeftAlone() {
        let reads = Reads()
        var written = false
        let cache = CodexRolloutCache(retryDelays: [0, 1, 5]) { path in
            reads.paths.append(path)
            return written ? .subagent(self.metadata) : .unavailable
        }
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(cache.inspection(transcriptPath: "/r/c.jsonl", now: start), .unavailable)
        XCTAssertEqual(cache.inspection(transcriptPath: "/r/c.jsonl", now: start + 0.5), .unavailable)
        XCTAssertEqual(reads.paths.count, 1, "not before its next lookup is due")

        XCTAssertEqual(cache.inspection(transcriptPath: "/r/c.jsonl", now: start + 1), .unavailable)
        XCTAssertEqual(reads.paths.count, 2)
        written = true
        XCTAssertEqual(cache.inspection(transcriptPath: "/r/c.jsonl", now: start + 5).metadata, metadata)
        XCTAssertEqual(cache.inspection(transcriptPath: "/r/c.jsonl", now: start + 6).metadata, metadata)
        XCTAssertEqual(reads.paths.count, 3)

        // A rollout that never becomes readable is left alone after its last lookup.
        written = false
        for offset in [0.0, 1, 5, 60, 600] {
            _ = cache.inspection(transcriptPath: "/r/o.jsonl", now: start + offset)
        }
        XCTAssertEqual(reads.paths.count, 6)
    }

    func testCacheStaysBounded() {
        let reads = Reads()
        let cache = CodexRolloutCache(capacity: 4) { path in
            reads.paths.append(path)
            return .root
        }
        for n in 0..<4 { _ = cache.inspection(transcriptPath: "/r/\(n)") }
        _ = cache.inspection(transcriptPath: "/r/4")
        _ = cache.inspection(transcriptPath: "/r/4")
        _ = cache.inspection(transcriptPath: "/r/0")
        XCTAssertEqual(reads.paths, ["/r/0", "/r/1", "/r/2", "/r/3", "/r/4", "/r/0"])
    }
}
