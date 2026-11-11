import XCTest
@testable import CodeIslandCore

/// Agent Sub-Sessions applied the same way to every kind of child session:
/// each kind's resolver produces a ``SubsessionLink`` and
/// ``SubsessionRouter`` places it.
final class SubsessionRouterTests: XCTestCase {
    private let parent = "parent-session"
    private let child = "child-session"
    private let cursorChat = "e1247fd5-d9a0-48ef-8457-0304606b1833"
    private let cursorTask = "2528cb91-6379-48f2-aff8-40f4b804dafa"

    private var cursorTranscript: String {
        "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/\(cursorChat).jsonl"
    }

    // MARK: - Payloads, one per kind of evidence

    private func declared(_ event: String = "PreToolUse") -> [String: Any] {
        ["hook_event_name": event, "session_id": child, "_source": "pi", DeclaredSubsession.parentKey: parent]
    }

    private func cursorByTranscript(_ event: String = "beforeReadFile") -> [String: Any] {
        ["hook_event_name": event, "session_id": cursorTask, "_source": "cursor", "transcript_path": cursorTranscript]
    }

    private func cursorByProcess(_ event: String = "beforeReadFile") -> [String: Any] {
        ["hook_event_name": event, "session_id": cursorTask, "_source": "cursor", "_ppid": 4242]
    }

    private func codexThread(_ event: String = "PreToolUse", transcript: String = "/rollouts/child.jsonl") -> [String: Any] {
        ["hook_event_name": event, "session_id": child, "_source": "codex", "transcript_path": transcript, "_ppid": 7070]
    }

    private func codexFiledUnderParent(_ event: String = "PreToolUse") -> [String: Any] {
        ["hook_event_name": event, "session_id": parent, "_source": "codex", "agent_id": child, "agent_type": "worker"]
    }

    private func pluginProxy(_ event: String = "PostToolUse") -> [String: Any] {
        ["hook_event_name": event, "session_id": child, "_source": "opencode", "_via_plugin": true, "_ppid": 9090]
    }

    private var childRollout: CodexTranscriptSubagentInspection {
        .subagent(CodexSubagentMetadata(parentThreadId: parent, agentType: "worker", agentNickname: "Ohm"))
    }

    // MARK: - Helpers

    private func link(_ raw: [String: Any], _ context: StubSubsessionContext, file: StaticString = #filePath, line: UInt = #line) throws -> SubsessionLink {
        try XCTUnwrap(SubsessionRouter.link(in: raw, context: context), "no link for \(raw)", file: file, line: line)
    }

    private func placement(
        _ raw: [String: Any],
        _ mode: SubsessionMode,
        _ context: StubSubsessionContext,
        blocking: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SubsessionPlacement {
        SubsessionRouter.placement(
            for: try link(raw, context, file: file, line: line),
            mode: mode,
            cards: context.cards,
            isBlockingRequest: { blocking }
        )
    }

    // MARK: - Every kind × every mode

    func testDeclaredChildInEveryMode() throws {
        let noParent = StubSubsessionContext()
        let withParent = StubSubsessionContext(cards: [parent: subsessionCard(source: "pi")])
        XCTAssertEqual(try placement(declared(), .separate, withParent), .ownCard(linkedTo: parent))
        XCTAssertEqual(try placement(declared(), .merge, withParent), .fold(into: parent))
        XCTAssertEqual(try placement(declared(), .merge, noParent), .ownCard(linkedTo: parent), "an unknown parent is not invented")
        XCTAssertEqual(try placement(declared(), .hide, withParent), .hidden)
        XCTAssertEqual(try placement(declared("PermissionRequest"), .hide, withParent, blocking: true), .ownCard(linkedTo: parent))
    }

    func testCursorTaskNamedByItsTranscriptInEveryMode() throws {
        let context = StubSubsessionContext()
        XCTAssertEqual(try placement(cursorByTranscript(), .separate, context), .ownCard(linkedTo: cursorChat))
        XCTAssertEqual(
            try placement(cursorByTranscript(), .merge, context), .fold(into: cursorChat),
            "the transcript names the chat's own session id: its card may be created"
        )
        XCTAssertEqual(try placement(cursorByTranscript(), .hide, context), .hidden)
    }

    func testCursorTaskFoundByItsIdeProcessInEveryMode() throws {
        var chat = subsessionCard(source: "cursor", status: .running, transcriptPath: cursorTranscript, cliPid: 4242)
        chat.providerSessionId = cursorChat
        let context = StubSubsessionContext(cards: [cursorChat: chat])
        let guess = try link(cursorByProcess(), context)
        XCTAssertTrue(guess.isInferred)
        XCTAssertEqual(guess.parentCardId, cursorChat)
        XCTAssertEqual(try placement(cursorByProcess(), .separate, context), .unchanged, "Show separately does not act on a guess")
        XCTAssertEqual(try placement(cursorByProcess(), .merge, context), .fold(into: cursorChat))
        XCTAssertEqual(try placement(cursorByProcess(), .hide, context), .hidden)
    }

    func testCodexThreadNamedByItsRolloutInEveryMode() throws {
        let noParent = StubSubsessionContext(rollouts: ["/rollouts/child.jsonl": childRollout])
        let withParent = StubSubsessionContext(
            cards: [parent: subsessionCard(source: "codex", providerSessionId: parent)],
            rollouts: ["/rollouts/child.jsonl": childRollout]
        )
        XCTAssertEqual(try placement(codexThread(), .separate, withParent), .ownCard(linkedTo: parent))
        XCTAssertEqual(
            try placement(codexThread(), .separate, noParent), .ownCard(linkedTo: parent),
            "a parent thread the island has no card for yet still makes it a child"
        )
        XCTAssertEqual(try placement(codexThread(), .merge, withParent), .fold(into: parent))
        XCTAssertEqual(try placement(codexThread(), .merge, noParent), .ownCard(linkedTo: parent))
        XCTAssertEqual(try placement(codexThread(), .hide, withParent), .hidden)
        XCTAssertEqual(try placement(codexThread("PermissionRequest"), .hide, withParent, blocking: true), .ownCard(linkedTo: parent))
    }

    func testCodexThreadFoundByItsParentsProcessInEveryMode() throws {
        let context = StubSubsessionContext(cards: [
            parent: subsessionCard(source: "codex", status: .running, cliPid: 7070),
        ])
        let guess = try link(codexThread(), context)
        XCTAssertTrue(guess.isInferred)
        XCTAssertEqual(try placement(codexThread(), .separate, context), .unchanged)
        XCTAssertEqual(try placement(codexThread(), .merge, context), .fold(into: parent))
        XCTAssertEqual(try placement(codexThread(), .hide, context), .hidden)
    }

    func testSharedProcessIsGuessedOnlyOnTheHooksOwnHost() throws {
        // A process id means nothing on another machine. A remote card keeps
        // its host's pid apart from `cliPid`, which names a process here.
        var remoteParent = subsessionCard(source: "codex", status: .running)
        remoteParent.remotePid = 7070
        remoteParent.remoteHostId = "devbox"
        let context = StubSubsessionContext(cards: [
            parent: subsessionCard(source: "codex", status: .running, cliPid: 7070),
            "remote:devbox:remote-parent": remoteParent,
        ])
        func remote(_ host: String, _ raw: [String: Any]) -> [String: Any] {
            raw.merging(["_remote_host_id": host]) { _, new in new }
        }
        XCTAssertEqual(try link(codexThread(), context).parentCardId, parent)
        XCTAssertEqual(try link(remote("devbox", codexThread()), context).parentCardId, "remote:devbox:remote-parent")
        XCTAssertNil(SubsessionRouter.link(in: remote("other-box", codexThread()), context: context), "nobody's child")

        var opencode = subsessionCard(source: "opencode", status: .running)
        opencode.remotePid = 9090
        opencode.remoteHostId = "devbox"
        let proxies = StubSubsessionContext(cards: ["remote:devbox:opencode-main": opencode])
        XCTAssertNil(try link(pluginProxy(), proxies).parentCardId)
        XCTAssertEqual(try link(remote("devbox", pluginProxy()), proxies).parentCardId, "remote:devbox:opencode-main")

        var chat = subsessionCard(source: "cursor", status: .running, transcriptPath: cursorTranscript, cliPid: 4242)
        chat.providerSessionId = cursorChat
        let cursor = StubSubsessionContext(cards: [cursorChat: chat])
        XCTAssertNil(SubsessionRouter.link(in: remote("devbox", cursorByProcess()), context: cursor))
        XCTAssertEqual(try link(cursorByProcess(), cursor).parentCardId, cursorChat)
    }

    func testCodexThreadCodexFiledUnderItsParentInEveryMode() throws {
        var root = subsessionCard(source: "codex")
        let context = StubSubsessionContext(cards: [parent: root])
        let filed = try link(codexFiledUnderParent(), context)
        XCTAssertTrue(filed.isProviderFolded)
        XCTAssertEqual(filed.agentId, child)
        XCTAssertEqual(try placement(codexFiledUnderParent(), .separate, context), .unchanged)
        XCTAssertEqual(try placement(codexFiledUnderParent(), .merge, context), .unchanged)
        XCTAssertEqual(try placement(codexFiledUnderParent(), .hide, context), .hidden)
        XCTAssertEqual(
            try placement(codexFiledUnderParent("PermissionRequest"), .hide, context, blocking: true), .unchanged,
            "a request it is blocked on still reaches the user"
        )
        // Once that request put the child on the card, it stays visible until it ends.
        root.subagents[child] = SubagentState(agentId: child, agentType: "worker")
        context.cards[parent] = root
        XCTAssertEqual(try placement(codexFiledUnderParent(), .hide, context), .unchanged)
    }

    func testPluginProxyInEveryMode() throws {
        let alone = StubSubsessionContext()
        let withAgent = StubSubsessionContext(cards: [
            "opencode-main": subsessionCard(source: "opencode", status: .running, cliPid: 9090),
        ])
        XCTAssertEqual(try link(pluginProxy(), withAgent).parentCardId, "opencode-main")
        XCTAssertEqual(try placement(pluginProxy(), .separate, withAgent), .unchanged, "the agent's card is only a guess")
        XCTAssertEqual(try placement(pluginProxy(), .merge, withAgent), .fold(into: "opencode-main"))
        XCTAssertEqual(try placement(pluginProxy(), .merge, alone), .unchanged)
        XCTAssertEqual(try placement(pluginProxy(), .hide, alone), .hidden, "a proxy is hidden even when its agent has no card")
        // Answered `{}`: undecided, so the agent asks the user itself (#165).
        for context in [alone, withAgent] {
            XCTAssertEqual(try placement(pluginProxy("PermissionRequest"), .hide, context, blocking: true), .hidden)
        }
        // A card of its own does not bring it back in Hide. In Merge a proxy
        // whose hooks built one before its agent's card keeps it, linked.
        withAgent.cards[child] = subsessionCard(source: "opencode")
        XCTAssertEqual(try placement(pluginProxy(), .hide, withAgent), .hidden)
        XCTAssertEqual(try placement(pluginProxy(), .merge, withAgent), .ownCard(linkedTo: "opencode-main"))
    }

    func testHookOfASessionNobodySpawnedHasNoLink() {
        let context = StubSubsessionContext(rollouts: ["/rollouts/root.jsonl": .root])
        XCTAssertNil(SubsessionRouter.link(in: ["hook_event_name": "Stop", "session_id": parent], context: context))
        XCTAssertNil(SubsessionRouter.link(in: codexThread(transcript: "/rollouts/root.jsonl"), context: context))
        XCTAssertNil(SubsessionRouter.link(in: [
            "hook_event_name": "Stop", "session_id": cursorChat, "_source": "cursor", "transcript_path": cursorTranscript,
        ], context: context))
    }

    // MARK: - A child stays where it is

    func testChildWithACardOfItsOwnKeepsItWhateverTheMode() throws {
        var linked = subsessionCard(source: "codex")
        linked.parentSessionId = parent
        let context = StubSubsessionContext(
            cards: [parent: subsessionCard(source: "codex"), child: linked],
            rollouts: ["/rollouts/child.jsonl": childRollout]
        )
        for mode in [SubsessionMode.merge, .hide] {
            XCTAssertEqual(try placement(codexThread(), mode, context), .ownCard(linkedTo: parent), "\(mode)")
        }
        // Every hook of a declared child says it is one: any card of its own
        // is one the router left it on.
        context.cards[child] = subsessionCard(source: "pi")
        for mode in [SubsessionMode.merge, .hide] {
            XCTAssertEqual(try placement(declared(), mode, context), .ownCard(linkedTo: parent), "\(mode)")
        }
    }

    func testCardBuiltBeforeTheChildWasKnownHoldsNothing() throws {
        // A Codex thread's first hook came before its rollout was readable:
        // the card it built is nobody's child.
        let codex = StubSubsessionContext(
            cards: [parent: subsessionCard(source: "codex"), child: subsessionCard(source: "codex")],
            rollouts: ["/rollouts/child.jsonl": childRollout]
        )
        XCTAssertEqual(try placement(codexThread(), .merge, codex), .fold(into: parent))
        XCTAssertEqual(try placement(codexThread(), .hide, codex), .hidden)
        XCTAssertEqual(try placement(codexThread(), .separate, codex), .ownCard(linkedTo: parent), "linked from now on")

        // A Cursor Task's Claude-format hook built a default card before its
        // IDE process named its chat.
        var chat = subsessionCard(source: "cursor", status: .running, transcriptPath: cursorTranscript, cliPid: 4242)
        chat.providerSessionId = cursorChat
        let cursor = StubSubsessionContext(cards: [cursorChat: chat, cursorTask: subsessionCard(source: "claude")])
        XCTAssertEqual(try placement(cursorByProcess(), .merge, cursor), .fold(into: cursorChat))
        XCTAssertEqual(try placement(cursorByProcess(), .hide, cursor), .hidden)
    }

    func testFoldedChildFollowsItsRowWhateverTheModeOrEvidence() throws {
        var host = subsessionCard(source: "cursor", status: .running)
        var row = SubagentState(agentId: cursorTask, agentType: "cursor-subagent")
        row.subsessionKind = .cursorTask
        host.subagents[cursorTask] = row
        // Two chats on the IDE process: the `_ppid` fallback can no longer
        // single one out, but the Task already lives on `host`.
        let context = StubSubsessionContext(cards: [
            "chat-a": host,
            "chat-b": subsessionCard(source: "cursor", status: .running, cliPid: 4242),
            "chat-c": subsessionCard(source: "cursor", status: .running, cliPid: 4242),
        ])
        for mode in [SubsessionMode.separate, .merge, .hide] {
            XCTAssertEqual(try placement(cursorByProcess(), mode, context), .fold(into: "chat-a"), "\(mode)")
        }
    }

    func testAgentsOwnSubagentRowDoesNotPullAChildOffItsCard() throws {
        // A Codex parent's SubagentStart made a row for the thread; its own
        // hooks keep a card of their own in Show separately.
        var root = subsessionCard(source: "codex", providerSessionId: parent)
        root.subagents[child] = SubagentState(agentId: child, agentType: "worker")
        let context = StubSubsessionContext(cards: [parent: root], rollouts: ["/rollouts/child.jsonl": childRollout])
        XCTAssertEqual(try placement(codexThread(), .separate, context), .ownCard(linkedTo: parent))
        XCTAssertEqual(try placement(codexThread(), .merge, context), .fold(into: parent))
    }

    func testGrandchildFoldsIntoTheCardItsParentIsFoldedInto() throws {
        var root = subsessionCard(source: "pi")
        var folded = SubagentState(agentId: parent, agentType: "worker")
        folded.subsessionKind = .declared
        root.subagents[parent] = folded
        let context = StubSubsessionContext(cards: ["root": root])
        XCTAssertEqual(try placement(declared(), .merge, context), .fold(into: "root"))

        // A Codex grandchild names its parent thread, folded as a row by its raw id.
        var codexRoot = subsessionCard(source: "codex", termBundleId: "com.openai.codex")
        var codexParent = SubagentState(agentId: parent, agentType: "worker")
        codexParent.subsessionKind = .codexThread
        codexRoot.subagents[parent] = codexParent
        let desktop = StubSubsessionContext(
            cards: ["codexapp:root": codexRoot],
            rollouts: ["/rollouts/child.jsonl": childRollout]
        )
        var grandchild = codexThread()
        grandchild["_term_bundle"] = "com.openai.codex"
        XCTAssertEqual(try placement(grandchild, .merge, desktop), .fold(into: "codexapp:root"))
    }

    func testGrandchildCodexFiledUnderItsParentThreadJoinsTheCardItsParentIsOn() throws {
        // Codex filed the grandchild's hook under its parent thread, which
        // has no card of its own: Codex filed that thread as a row of the
        // root's card.
        var root = subsessionCard(source: "codex")
        root.subagents[parent] = SubagentState(agentId: parent, agentType: "worker")
        let context = StubSubsessionContext(cards: ["root": root])
        for mode in [SubsessionMode.separate, .merge] {
            XCTAssertEqual(try placement(codexFiledUnderParent(), mode, context), .fold(into: "root"), "\(mode)")
        }
        XCTAssertEqual(try placement(codexFiledUnderParent(), .hide, context), .hidden)
        XCTAssertEqual(try placement(codexFiledUnderParent("PermissionRequest"), .hide, context, blocking: true), .fold(into: "root"))

        var raw = codexFiledUnderParent()
        XCTAssertEqual(
            SubsessionRouter.route(&raw, link: try link(raw, context), mode: .merge, cards: context.cards, isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(raw["session_id"] as? String, "root")
        XCTAssertEqual(raw["agent_id"] as? String, child)
        XCTAssertEqual(raw["agent_type"] as? String, "worker")

        // Its row stays its place once its parent's row is gone.
        var folded = SubagentState(agentId: child, agentType: "worker")
        folded.subsessionKind = .codexThread
        root.subagents = [child: folded]
        context.cards["root"] = root
        XCTAssertEqual(try placement(codexFiledUnderParent(), .merge, context), .fold(into: "root"))

        // With neither, it stays where Codex filed it.
        context.cards["root"] = subsessionCard(source: "codex")
        XCTAssertEqual(try placement(codexFiledUnderParent(), .merge, context), .unchanged)
    }

    // MARK: - The rewrite

    func testFoldRewritesEveryKindOntoTheHostAsItsSubagent() throws {
        let context = StubSubsessionContext(
            cards: [parent: subsessionCard(source: "codex", providerSessionId: parent)],
            rollouts: ["/rollouts/child.jsonl": childRollout]
        )
        var codex = codexThread()
        XCTAssertEqual(
            SubsessionRouter.route(&codex, link: try link(codex, context), mode: .merge, cards: context.cards, isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(codex["session_id"] as? String, parent)
        XCTAssertEqual(codex["agent_id"] as? String, child)
        XCTAssertEqual(codex["agent_type"] as? String, "worker", "the rollout's role")
        XCTAssertEqual(codex[SubsessionRouter.foldedKey] as? String, "codex")

        var misbranded: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": cursorTask, "_source": "claude",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/subagents/\(cursorTask).jsonl",
        ]
        let cursorLink = try link(misbranded, StubSubsessionContext())
        XCTAssertTrue(SubsessionRouter.fold(&misbranded, link: cursorLink, into: cursorChat))
        XCTAssertEqual(misbranded["_source"] as? String, "cursor")
        XCTAssertEqual(misbranded["agent_type"] as? String, "cursor-subagent")
        XCTAssertEqual(misbranded[SubsessionRouter.foldedKey] as? String, "cursor")
    }

    func testPluginProxyJoinsItsAgentsCardAsItsOwnEvents() throws {
        let context = StubSubsessionContext(cards: [
            "opencode-main": subsessionCard(source: "opencode", status: .running, cliPid: 9090),
        ])
        var raw = pluginProxy("Stop")
        XCTAssertEqual(
            SubsessionRouter.route(&raw, link: try link(raw, context), mode: .merge, cards: context.cards, isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(raw["session_id"] as? String, "opencode-main")
        XCTAssertNil(raw["agent_id"], "omo mirrors the session's own turn: no subagent row waiting on a Stop")
        XCTAssertNil(raw[SubsessionRouter.foldedKey])
    }

    func testChildOnItsOwnCardIsLinkedToItsParent() throws {
        let context = StubSubsessionContext(rollouts: ["/rollouts/child.jsonl": childRollout])
        var raw = codexThread("Stop")
        XCTAssertEqual(
            SubsessionRouter.route(&raw, link: try link(raw, context), mode: .separate, cards: context.cards, isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(raw["session_id"] as? String, child)
        XCTAssertEqual(SubsessionRouter.parentCardId(in: raw), parent)

        // A declared child already says so: nothing to rewrite.
        var pi = declared("Stop")
        XCTAssertEqual(
            SubsessionRouter.route(&pi, link: try link(pi, context), mode: .separate, cards: [:], isBlockingRequest: { false }),
            .unchanged
        )
    }

    func testFoldThePayloadCannotAddressKeepsTheChildOnItsOwnLinkedCard() throws {
        // A Codex Desktop thread can only land on a `codexapp:` card.
        var raw = codexThread()
        raw["_term_bundle"] = "com.openai.codex"
        let link = SubsessionLink(kind: .codexThread, childCardId: "codexapp:\(child)", agentId: child, parentCardId: "cli-parent")
        XCTAssertEqual(
            SubsessionRouter.route(&raw, link: link, mode: .merge, cards: ["cli-parent": subsessionCard(source: "codex")], isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(raw["session_id"] as? String, child)
        XCTAssertNil(raw["agent_id"])
        XCTAssertEqual(raw[SubsessionRouter.linkedParentKey] as? String, "cli-parent")
    }

    // MARK: - Resolution order

    func testDeclaredParentBeatsEveryOtherResolver() throws {
        var raw = cursorByTranscript()
        raw[DeclaredSubsession.parentKey] = parent
        XCTAssertEqual(try link(raw, StubSubsessionContext()).kind, .declared)
    }

    func testSessionIsNeverItsOwnParent() {
        // A Task card that reused the chat's id as its provider session id.
        var task = subsessionCard(source: "cursor")
        task.providerSessionId = cursorChat
        let context = StubSubsessionContext(cards: [cursorTask: task])
        XCTAssertEqual(SubsessionRouter.link(in: cursorByTranscript(), context: context)?.parentCardId, cursorChat)
        XCTAssertNil(DeclaredSubsession.link(in: ["session_id": child, DeclaredSubsession.parentKey: child]))
    }

    func testReducerReadsTheRoutersLinkBeforeTheDeclaration() {
        XCTAssertEqual(SubsessionRouter.parentCardId(in: [
            "session_id": child, DeclaredSubsession.parentKey: parent, SubsessionRouter.linkedParentKey: "linked",
        ]), "linked")
        XCTAssertEqual(SubsessionRouter.parentCardId(in: ["session_id": child, DeclaredSubsession.parentKey: parent]), parent)
        XCTAssertNil(SubsessionRouter.parentCardId(in: ["session_id": child, SubsessionRouter.linkedParentKey: " "]))
    }

    func testProcessIdOutsidePidRangeIsIgnored() {
        XCTAssertEqual(SubsessionRouter.positivePpid(in: ["_ppid": "4242"]), 4242)
        XCTAssertEqual(SubsessionRouter.positivePpid(in: ["_ppid": NSNumber(value: 4242)]), 4242)
        XCTAssertNil(SubsessionRouter.positivePpid(in: ["_ppid": "99999999999"]))
        XCTAssertNil(SubsessionRouter.positivePpid(in: ["_ppid": NSNumber(value: Int64(1) << 40)]))
        XCTAssertNil(SubsessionRouter.positivePpid(in: ["_ppid": 0]))
        // A malformed one never reaches a PID comparison, which trapped on it.
        let context = StubSubsessionContext(cards: [
            cursorChat: subsessionCard(source: "cursor", status: .running, cliPid: 4242),
            parent: subsessionCard(source: "codex", status: .running, cliPid: 4242),
        ])
        for source in ["cursor", "codex"] {
            XCTAssertNil(SubsessionRouter.link(in: [
                "hook_event_name": "PreToolUse", "session_id": cursorTask, "_source": source, "_ppid": "99999999999",
            ], context: context), source)
        }
        // Nor does the public lookup trap on one handed to it.
        XCTAssertNil(SubsessionCards.samePidCard(source: "codex", ppid: 9_999_999_999, remoteHostId: nil, in: context.cards))
        XCTAssertEqual(SubsessionCards.samePidCard(source: "codex", ppid: 4242, remoteHostId: nil, in: context.cards), parent)
    }

    func testUnknownSettingReadsAsShowSeparately() {
        XCTAssertEqual(SubsessionMode(setting: nil), .separate)
        XCTAssertEqual(SubsessionMode(setting: "bogus"), .separate)
        XCTAssertEqual(SubsessionMode(setting: "merge"), .merge)
        XCTAssertEqual(SubsessionMode(setting: "hide"), .hide)
    }
}
