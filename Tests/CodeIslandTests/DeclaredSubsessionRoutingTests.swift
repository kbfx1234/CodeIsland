import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A child that names its parent (`_parent_session_id`, #378) — a
/// pi-subagents child, each one a pi session of its own that used to ring
/// the completion sound like the session the user started. Hooks go through
/// HookServer's Agent Sub-Sessions routing and then AppState, as in the app.
@MainActor
final class DeclaredSubsessionRoutingTests: XCTestCase {
    private let parentId = "pi-01a15910-e6c0-75af-93e2-e9c1825affc1"
    private let childId = "pi-01a15911-8771-7000-8000-000000000001"
    private let siblingId = "pi-01a15911-877f-7000-8000-000000000002"
    private let grandchildId = "pi-01a15912-0000-7000-8000-000000000003"

    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.pluginSessionMode,
        SettingsKey.soundEnabled,
        SettingsKey.soundSessionStart,
        SettingsKey.soundTaskComplete,
        SettingsKey.soundTaskError,
        SettingsKey.soundApprovalNeeded,
        SettingsKey.soundPromptSubmit,
        SettingsKey.quietHoursEnabled,
        SettingsKey.autoMuteWhenAway,
        SettingsKey.smartSuppress,
        SettingsKey.completionNotificationStyle,
    ]

    override func setUp() {
        super.setUp()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SettingsKey.soundEnabled)
        defaults.set(true, forKey: SettingsKey.soundSessionStart)
        defaults.set(true, forKey: SettingsKey.soundTaskComplete)
        defaults.set(true, forKey: SettingsKey.soundTaskError)
        defaults.set(true, forKey: SettingsKey.soundApprovalNeeded)
        defaults.set(false, forKey: SettingsKey.soundPromptSubmit)
        defaults.set(false, forKey: SettingsKey.quietHoursEnabled)
        defaults.set(false, forKey: SettingsKey.autoMuteWhenAway)
        defaults.set(false, forKey: SettingsKey.smartSuppress)
        defaults.set("expand", forKey: SettingsKey.completionNotificationStyle)
        defaults.set("separate", forKey: SettingsKey.pluginSessionMode)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    // MARK: - Helpers

    private func setMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: SettingsKey.pluginSessionMode)
    }

    private func parent(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": event, "session_id": parentId, "_source": "pi"]
            .merging(extra) { _, new in new }
    }

    private func child(_ event: String, id: String? = nil, parent: String? = nil, _ extra: [String: Any] = [:]) -> [String: Any] {
        [
            "hook_event_name": event,
            "session_id": id ?? childId,
            "_source": "pi",
            DeclaredSubsession.parentKey: parent ?? parentId,
            "agent_type": "worker",
        ].merging(extra) { _, new in new }
    }

    private struct Routed {
        let raw: [String: Any]
        let data: Data
        let response: Data?
        var sessionId: String? { raw["session_id"] as? String }
    }

    private func route(_ payload: [String: Any], server: HookServer) throws -> Routed {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: routed.processedData) as? [String: Any])
        return Routed(raw: raw, data: routed.processedData, response: routed.responseData)
    }

    /// Route a non-blocking hook and hand it to AppState, as HookServer does.
    @discardableResult
    private func deliver(_ payload: [String: Any], to appState: AppState, server: HookServer) throws -> Routed {
        let routed = try route(payload, server: server)
        if routed.response == nil {
            appState.handleEvent(try XCTUnwrap(HookEvent(from: routed.data)))
        }
        return routed
    }

    private func childTurn(_ id: String, appState: AppState, server: HookServer) throws {
        try deliver(child("SessionStart", id: id, ["session_title": "worker: sleep 4"]), to: appState, server: server)
        try deliver(child("UserPromptSubmit", id: id, ["prompt": "Task: sleep 4"]), to: appState, server: server)
        try deliver(child("PreToolUse", id: id, ["tool_name": "Bash", "tool_input": ["command": "sleep 4"]]), to: appState, server: server)
        try deliver(child("PostToolUse", id: id), to: appState, server: server)
        try deliver(child("Stop", id: id, ["last_assistant_message": "done"]), to: appState, server: server)
    }

    // MARK: - Separate (default)

    /// The issue's own scenario: one parent fanning out to two children rang
    /// `8bit_complete` three times. Only the parent's own turn may ring.
    func testSeparateModeOnlyTheParentRings() throws {
        let appState = AppState()
        let server = HookServer(appState: appState)

        try deliver(parent("SessionStart"), to: appState, server: server)
        try deliver(parent("UserPromptSubmit", ["prompt": "fan out to 2 subagents"]), to: appState, server: server)
        try deliver(parent("PreToolUse", ["tool_name": "Subagent"]), to: appState, server: server)

        for id in [childId, siblingId] {
            try childTurn(id, appState: appState, server: server)
            XCTAssertEqual(appState.sessions[id]?.parentSessionId, parentId, "kept on its own card, linked")
            XCTAssertEqual(appState.sessions[id]?.status, .idle)
            XCTAssertNil(appState.justCompletedSessionId, "a child's turn pops no completion card")
            XCTAssertNotEqual(appState.activeSessionId, id, "a finished child hands the spot back")
        }
        XCTAssertEqual(played, ["8bit_start"], "children neither start nor finish audibly")

        for id in [childId, siblingId] {
            try deliver(child("SessionEnd", id: id), to: appState, server: server)
            XCTAssertNil(appState.sessions[id])
        }
        try deliver(parent("PostToolUse"), to: appState, server: server)
        try deliver(parent("Stop", ["last_assistant_message": "all done"]), to: appState, server: server)

        XCTAssertEqual(played, ["8bit_start", "8bit_complete"], "the parent chimes exactly once")
        XCTAssertEqual(appState.justCompletedSessionId, parentId)
    }

    func testSeparateModeChildApprovalStillAsksAndRings() async throws {
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(child("SessionStart"), to: appState, server: server)
        try deliver(child("UserPromptSubmit", ["prompt": "Task: clean up"]), to: appState, server: server)
        XCTAssertEqual(played, [])

        let routed = try route(child("PermissionRequest", [
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"],
            "_pi_tool_call_id": "call-1",
        ]), server: server)
        XCTAssertNil(routed.response)
        let event = try XCTUnwrap(HookEvent(from: routed.data))
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        XCTAssertEqual(appState.permissionQueue.count, 1, "the user still has to answer it")
        XCTAssertEqual(appState.sessions[childId]?.status, .waitingApproval)
        XCTAssertEqual(played, ["8bit_approval"])

        appState.handlePeerDisconnect(sessionId: childId)
        _ = try await awaitValue(of: task)
    }

    // MARK: - Merge

    func testMergeModeFoldsChildrenIntoTheParentAndRingsOnce() throws {
        setMode("merge")
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(parent("SessionStart"), to: appState, server: server)
        try deliver(parent("UserPromptSubmit", ["prompt": "fan out to 2 subagents"]), to: appState, server: server)

        let first = try deliver(child("SessionStart"), to: appState, server: server)
        XCTAssertEqual(first.sessionId, parentId)
        XCTAssertEqual(first.raw["agent_id"] as? String, childId)
        XCTAssertEqual(first.raw["agent_type"] as? String, "worker")
        XCTAssertNil(first.raw[DeclaredSubsession.parentKey])
        try deliver(child("SessionStart", id: siblingId), to: appState, server: server)
        XCTAssertEqual(Set(appState.sessions[parentId]?.subagents.keys.map { $0 } ?? []), [childId, siblingId])

        try deliver(child("UserPromptSubmit", ["prompt": "Task: sleep 4"]), to: appState, server: server)
        try deliver(child("PreToolUse", ["tool_name": "Bash"]), to: appState, server: server)
        try deliver(child("PostToolUse"), to: appState, server: server)
        try deliver(child("Stop"), to: appState, server: server)
        XCTAssertNil(appState.sessions[parentId]?.subagents[childId])
        XCTAssertEqual(appState.sessions[parentId]?.status, .running, "its sibling is still working")
        try childTurn(siblingId, appState: appState, server: server)
        XCTAssertNotEqual(appState.sessions[parentId]?.status, .idle, "a child's Stop is not the parent's")
        try deliver(child("SessionEnd"), to: appState, server: server)
        try deliver(child("SessionEnd", id: siblingId), to: appState, server: server)

        XCTAssertNil(appState.sessions[childId])
        XCTAssertNil(appState.sessions[siblingId])
        XCTAssertNil(appState.justCompletedSessionId)
        XCTAssertEqual(played, ["8bit_start"])

        try deliver(parent("Stop", ["last_assistant_message": "all done"]), to: appState, server: server)
        XCTAssertEqual(played, ["8bit_start", "8bit_complete"])
        XCTAssertEqual(appState.sessions[parentId]?.status, .idle)
        XCTAssertEqual(appState.justCompletedSessionId, parentId)
    }

    func testMergeModeKeepsAChildOfAnUnknownParentOnItsOwnQuietCard() throws {
        setMode("merge")
        let appState = AppState()
        let server = HookServer(appState: appState)

        let start = try deliver(child("SessionStart"), to: appState, server: server)
        XCTAssertEqual(start.sessionId, childId, "no parent card to fold into: none is invented")
        XCTAssertNil(appState.sessions[parentId])

        // The parent's card turning up later does not pull the child off its own.
        try deliver(parent("UserPromptSubmit", ["prompt": "hi"]), to: appState, server: server)
        let stop = try deliver(child("Stop"), to: appState, server: server)
        XCTAssertEqual(stop.sessionId, childId)
        XCTAssertEqual(appState.sessions[childId]?.parentSessionId, parentId)
        XCTAssertNil(appState.justCompletedSessionId)
        XCTAssertFalse(played.contains("8bit_complete"))
    }

    func testMergeModeFoldsAGrandchildIntoTheCardItsParentIsFoldedInto() throws {
        setMode("merge")
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(parent("UserPromptSubmit", ["prompt": "fan out"]), to: appState, server: server)
        try deliver(child("SessionStart"), to: appState, server: server)
        XCTAssertNotNil(appState.sessions[parentId]?.subagents[childId])

        let grandchild = try deliver(child("SessionStart", id: grandchildId, parent: childId), to: appState, server: server)
        XCTAssertEqual(grandchild.sessionId, parentId)
        XCTAssertEqual(grandchild.raw["agent_id"] as? String, grandchildId)
        XCTAssertNotNil(appState.sessions[parentId]?.subagents[grandchildId])
        XCTAssertNil(appState.sessions[childId])
        XCTAssertNil(appState.sessions[grandchildId])
    }

    // MARK: - Hide

    func testHideModeHidesTheChildButNeverAnswersForTheUser() async throws {
        setMode("hide")
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(parent("UserPromptSubmit", ["prompt": "fan out"]), to: appState, server: server)

        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse"] {
            let hidden = try deliver(child(event, ["prompt": "Task"]), to: appState, server: server)
            XCTAssertEqual(hidden.response.flatMap { String(data: $0, encoding: .utf8) }, "{}")
        }
        XCTAssertNil(appState.sessions[childId])
        XCTAssertTrue(appState.sessions[parentId]?.subagents.isEmpty == true)

        // A dangerous command the child is blocked on is not auto-approved: it
        // goes to the user, on a card of the child's own.
        let request = try route(child("PermissionRequest", [
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"],
            "_pi_tool_call_id": "call-1",
        ]), server: server)
        XCTAssertNil(request.response, "hide must not answer a permission request")
        XCTAssertEqual(request.sessionId, childId)
        let event = try XCTUnwrap(HookEvent(from: request.data))
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[childId]?.parentSessionId, parentId)

        // Once surfaced, the child stays visible until it ends — and stays quiet.
        appState.handlePeerDisconnect(sessionId: childId)
        _ = try await awaitValue(of: task)
        let stop = try deliver(child("Stop"), to: appState, server: server)
        XCTAssertNil(stop.response)
        XCTAssertFalse(played.contains("8bit_complete"))
        try deliver(child("SessionEnd"), to: appState, server: server)
        XCTAssertNil(appState.sessions[childId])
    }

    func testHideModeStillAsksAQuestionAChildIsBlockedOn() throws {
        setMode("hide")
        let appState = AppState()
        let server = HookServer(appState: appState)
        let question = try route(child("PermissionRequest", [
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"]]]]],
        ]), server: server)
        XCTAssertNil(question.response, "hide must not answer the child's question with nothing")
        XCTAssertEqual(question.sessionId, childId)
    }

    // MARK: - Agent Sub-Sessions changed mid-flight

    func testAChildKeepsItsCardAfterSwitchingToMergeOrHide() throws {
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(parent("UserPromptSubmit", ["prompt": "fan out"]), to: appState, server: server)
        try deliver(child("SessionStart"), to: appState, server: server)
        XCTAssertNotNil(appState.sessions[childId])

        for mode in ["merge", "hide"] {
            setMode(mode)
            let routed = try route(child("PreToolUse", ["tool_name": "Bash"]), server: server)
            XCTAssertEqual(routed.sessionId, childId, mode)
            XCTAssertNil(routed.response, mode)
        }
    }

    func testAFoldedChildStaysFoldedAfterSwitchingToSeparateOrHide() throws {
        setMode("merge")
        let appState = AppState()
        let server = HookServer(appState: appState)
        try deliver(parent("UserPromptSubmit", ["prompt": "fan out"]), to: appState, server: server)
        try deliver(child("SessionStart"), to: appState, server: server)

        for mode in ["separate", "hide"] {
            setMode(mode)
            let routed = try route(child("PreToolUse", ["tool_name": "Bash"]), server: server)
            XCTAssertEqual(routed.sessionId, parentId, "\(mode): its row must not be stranded on the parent")
            XCTAssertNil(routed.response, mode)
        }
        try deliver(child("Stop"), to: appState, server: server)
        XCTAssertTrue(appState.sessions[parentId]?.subagents.isEmpty == true)
    }

    // MARK: - Persistence

    func testPersistedChildKeepsItsParentAndOldFilesStillDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let legacy = #"{"sessionId":"s","source":"pi","startTime":"2026-10-20T12:00:00Z","lastActivity":"2026-10-20T12:01:00Z"}"#
        let old = try decoder.decode(PersistedSession.self, from: Data(legacy.utf8))
        XCTAssertNil(old.parentSessionId)

        var withParent = old
        withParent.parentSessionId = parentId
        let decoded = try decoder.decode(PersistedSession.self, from: encoder.encode(withParent))
        XCTAssertEqual(decoded.parentSessionId, parentId)
    }
}
