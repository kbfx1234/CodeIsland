import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Locks in the wire-level pieces of Kiro CLI support (#127) — the parts that
/// don't need a live Kiro install to verify, but where a typo would silently
/// break the whole integration: event-name mapping, default event list,
/// supported-source recognition, and the new `.kiroAgent` HookFormat.
final class KiroSupportTests: XCTestCase {

    // MARK: - EventNormalizer

    func testEventNormalizerMapsKiroAgentSpawnToSessionStart() {
        XCTAssertEqual(EventNormalizer.normalize("agentSpawn"), "SessionStart")
        XCTAssertEqual(EventNormalizer.normalize("AgentSpawn"), "SessionStart")
    }

    func testEventNormalizerMapsKiroUserPromptSubmitToInternalName() {
        // Kiro uses singular `userPromptSubmit`, distinct from Copilot's
        // `userPromptSubmitted` — both must normalize to "UserPromptSubmit".
        XCTAssertEqual(EventNormalizer.normalize("userPromptSubmit"), "UserPromptSubmit")
        XCTAssertEqual(EventNormalizer.normalize("userPromptSubmitted"), "UserPromptSubmit")
    }

    func testEventNormalizerCoversAllKiroEvents() {
        // The five events Kiro sends; if any of these silently fall through to
        // the `default` branch (returning the raw camelCase name), HookServer
        // routing will misbehave — assert the full set explicitly.
        XCTAssertEqual(EventNormalizer.normalize("agentSpawn"), "SessionStart")
        XCTAssertEqual(EventNormalizer.normalize("userPromptSubmit"), "UserPromptSubmit")
        XCTAssertEqual(EventNormalizer.normalize("preToolUse"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("postToolUse"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalize("stop"), "Stop")
    }

    // MARK: - SessionSnapshot supported source recognition

    func testKiroIsRecognizedAsSupportedSource() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("kiro"), "kiro")
    }

    func testKiroAliasesNormalizeToKiro() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("kiro-cli"), "kiro")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("kirocli"), "kiro")
        // Prefix-match path (via the hasPrefix("kiro") clause) — covers any
        // future "kiro-something" sub-brand without us needing to enumerate it.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("kiro-pro"), "kiro")
    }

    func testKiroDisplayName() {
        var snapshot = SessionSnapshot()
        snapshot.source = "kiro"
        XCTAssertEqual(snapshot.sourceLabel, "Kiro")
    }

    func testKiroTranscriptPromptIsProcessing() throws {
        let path = try writeKiroTranscript(#"{"kind":"Prompt","data":{}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .processing = AppState.kiroTranscriptStatus(path: path) else {
            return XCTFail("Prompt must represent an active turn")
        }
    }

    func testKiroTranscriptToolResultsIsProcessing() throws {
        let path = try writeKiroTranscript(#"{"kind":"ToolResults","data":{}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .processing = AppState.kiroTranscriptStatus(path: path) else {
            return XCTFail("ToolResults must represent an active turn")
        }
    }

    func testKiroTranscriptFinalAssistantMessageIsIdle() throws {
        let line = #"{"kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"done"}]}}"#
        let path = try writeKiroTranscript(line)
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .idle = AppState.kiroTranscriptStatus(path: path) else {
            return XCTFail("A final assistant message must settle the turn")
        }
    }

    @MainActor
    func testKiroTranscriptDeltaRefreshesAggregateStatus() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "kiro"
        session.status = .idle
        appState.sessions["kiro-session"] = session
        appState.refreshDerivedState()

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "kiro-session",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            turnStatus: .processing,
            hasActivity: true
        ))

        XCTAssertEqual(appState.status, .processing)
        XCTAssertEqual(appState.activeSessionCount, 1)
    }

    private func writeKiroTranscript(_ line: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data((line + "\n").utf8).write(to: url)
        return url.path
    }

    // MARK: - ConfigInstaller — Kiro CLIConfig + default events

    func testKiroDefaultEventsAreCamelCaseAndComplete() {
        // Kiro CLI hooks contract: 5 camelCase events. Order isn't strictly
        // required by Kiro, but locking it stabilizes the hook-install diff.
        let names = ConfigInstaller.defaultEvents(for: .kiroAgent).map { $0.0 }
        XCTAssertEqual(names, ["agentSpawn", "userPromptSubmit", "preToolUse", "postToolUse", "stop"])
    }

    func testHookFormatKiroAgentRoundTripsThroughStorageValue() {
        // `HookFormat.storageValue` is what we persist for custom CLIs in
        // UserDefaults; missing a case here would silently demote Kiro custom
        // configs to a different format on load.
        XCTAssertEqual(HookFormat.kiroAgent.storageValue, "kiroAgent")
        XCTAssertEqual(HookFormat(storageValue: "kiroAgent"), .kiroAgent)
        XCTAssertEqual(HookFormat(storageValue: "kiroagent"), .kiroAgent)  // case-insensitive
    }

    func testKiroHookMatcherIsValidCatchAllRegex() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("agent.json").path
        let cli = CLIConfig(
            name: "Kiro",
            source: "kiro",
            configPath: configPath,
            configKey: "hooks",
            format: .kiroAgent,
            events: [("userPromptSubmit", 5, true)]
        )

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let entry = try XCTUnwrap((hooks["userPromptSubmit"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["matcher"] as? String, ".*")
    }

    func testKiroV3OnlyInstallsTurnBoundaryHooks() {
        XCTAssertEqual(ConfigInstaller.kiroV3EventNames, [
            "UserPromptSubmit", "Stop"
        ])

        let startEntry = ConfigInstaller.kiroV3HookEntry(
            trigger: "UserPromptSubmit", name: "user-prompt-submit",
            command: "/tmp/codeisland-bridge --source kiro", timeout: 5
        )
        XCTAssertEqual(startEntry["name"] as? String, "codeisland-user-prompt-submit")
        XCTAssertEqual(startEntry["trigger"] as? String, "UserPromptSubmit")
        XCTAssertNil(startEntry["matcher"])
        XCTAssertEqual(startEntry["timeout"] as? Int, 5)
        XCTAssertEqual(startEntry["enabled"] as? Bool, true)
        let action = startEntry["action"] as? [String: Any]
        XCTAssertEqual(action?["type"] as? String, "command")
        XCTAssertEqual(action?["command"] as? String, "/tmp/codeisland-bridge --source kiro")

        let lifecycleEntry = ConfigInstaller.kiroV3HookEntry(
            trigger: "Stop", name: "stop",
            command: "/tmp/codeisland-bridge --source kiro", timeout: 5
        )
        XCTAssertNil(lifecycleEntry["matcher"])
    }

    func testKiroV3MigratesLegacyToolHooksWithoutTouchingOtherHooks() {
        let command = "/tmp/codeisland-bridge --source kiro"
        let legacy = [("AgentSpawn", "agent-spawn"), ("UserPromptSubmit", "user-prompt-submit"),
                      ("PreToolUse", "pre-tool-use"), ("PostToolUse", "post-tool-use"),
                      ("Stop", "stop")].map {
            ConfigInstaller.kiroV3HookEntry(trigger: $0.0, name: $0.1, command: command, timeout: 5)
        }
        let other: [String: Any] = ["name": "image-check", "trigger": "PreToolUse",
                                    "action": ["type": "command", "command": "/usr/bin/true"]]
        XCTAssertFalse(ConfigInstaller.kiroV3HooksInstalled(legacy + [other], command: command))

        let updated = ConfigInstaller.kiroV3Hooks(replacingManaged: legacy + [other], command: command)
        XCTAssertTrue(ConfigInstaller.kiroV3HooksInstalled(updated, command: command))
        XCTAssertEqual(updated.count, 3)
        XCTAssertEqual(updated.first?["name"] as? String, "image-check")
        XCTAssertEqual(Set(updated.compactMap { $0["trigger"] as? String }),
                       ["PreToolUse", "UserPromptSubmit", "Stop"])
        XCTAssertEqual(updated.filter { ($0["name"] as? String)?.hasPrefix("codeisland-") == true }.count, 2)
    }

    func testKiroV2AndV3EventNamesStayDistinct() {
        let v2 = ConfigInstaller.defaultEvents(for: .kiroAgent).map { $0.0 }
        XCTAssertEqual(v2, ["agentSpawn", "userPromptSubmit", "preToolUse", "postToolUse", "stop"])
        XCTAssertNotEqual(v2, ConfigInstaller.kiroV3EventNames)
    }

}
