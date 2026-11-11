import XCTest
@testable import CodeIslandCore

/// Claude Desktop Cowork session store: metadata parsing, path classification
/// and the ghost-card policy. Fixtures mirror the real on-disk shapes
/// (`local-agent-mode-sessions/<account>/<org>/local_<id>.json`).
final class CoworkSessionTests: XCTestCase {

    private let root = "/Users/alice/Library/Application Support/Claude/local-agent-mode-sessions"
    private let sessionId = "local_f421aa51-3c78-4391-bc5e-3a05c2218bee"

    private func realMetadataJSON(
        isArchived: Bool = false,
        extra: String = ""
    ) -> Data {
        Data("""
        {"sessionId":"\(sessionId)","processName":"bold-inspiring-tesla",\
        "cliSessionId":"d0a5dc71-0311-45bb-87b4-0ff74229f6ca","cwd":"/sessions/bold-inspiring-tesla",\
        "userSelectedFolders":["/Users/alice"],"createdAt":1768300792332,"lastActivityAt":1768300883496,\
        "model":"claude-opus-4-5-20251101","isArchived":\(isArchived),\
        "title":"Available installation packages inquiry","vmProcessName":"bold-inspiring-tesla",\
        "initialMessage":"which installers are here"\(extra)}
        """.utf8)
    }

    // MARK: - Metadata

    func testParsesRealMetadataShape() throws {
        let metadata = try XCTUnwrap(CoworkSessionMetadata.parse(realMetadataJSON()))
        XCTAssertEqual(metadata.sessionId, sessionId)
        XCTAssertEqual(metadata.cliSessionId, "d0a5dc71-0311-45bb-87b4-0ff74229f6ca")
        XCTAssertEqual(metadata.title, "Available installation packages inquiry")
        XCTAssertEqual(metadata.model, "claude-opus-4-5-20251101")
        XCTAssertEqual(metadata.userSelectedFolders, ["/Users/alice"])
        XCTAssertFalse(metadata.isArchived)
        XCTAssertNil(metadata.sessionType)
        // Epoch milliseconds, not seconds.
        XCTAssertEqual(try XCTUnwrap(metadata.createdAt).timeIntervalSince1970, 1_768_300_792.332, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metadata.lastActivityAt).timeIntervalSince1970, 1_768_300_883.496, accuracy: 0.001)
        // The VM cwd is meaningless on the host; the granted folder wins.
        XCTAssertEqual(metadata.hostCwd, "/Users/alice")
        XCTAssertEqual(metadata.displayTitle, "Available installation packages inquiry")
    }

    func testArchivedFlagAndSessionTypeAreRead() throws {
        let metadata = try XCTUnwrap(CoworkSessionMetadata.parse(
            realMetadataJSON(isArchived: true, extra: #","sessionType":"chat""#)
        ))
        XCTAssertTrue(metadata.isArchived)
        XCTAssertEqual(metadata.sessionType, "chat")
    }

    func testHostCwdIgnoresSandboxPathButKeepsHostLoopCwd() {
        var metadata = CoworkSessionMetadata(sessionId: sessionId, cwd: "/sessions/bold-inspiring-tesla")
        XCTAssertNil(metadata.hostCwd, "a /sessions/<vm> path does not exist on the Mac")
        metadata.cwd = "/Users/alice/code/app"
        XCTAssertEqual(metadata.hostCwd, "/Users/alice/code/app")
        metadata.userSelectedFolders = ["relative/ignored", "/Volumes/Work"]
        XCTAssertEqual(metadata.hostCwd, "/Volumes/Work")
    }

    func testDisplayTitleFallsBackToClippedOpeningPrompt() {
        let long = String(repeating: "word ", count: 40) + "\nsecond line"
        let metadata = CoworkSessionMetadata(sessionId: sessionId, initialMessage: long)
        let title = metadata.displayTitle ?? ""
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 81)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertNil(CoworkSessionMetadata(sessionId: sessionId).displayTitle)
    }

    func testRejectsMalformedOrForeignMetadata() {
        XCTAssertNil(CoworkSessionMetadata.parse(Data("{not json".utf8)))
        XCTAssertNil(CoworkSessionMetadata.parse(Data(#"{"sessionId":"cse_123"}"#.utf8)))
        XCTAssertNil(CoworkSessionMetadata.parse(Data(#"{"sessionId":"local_../../etc"}"#.utf8)))
        XCTAssertNil(CoworkSessionMetadata.parse(Data(#"{"title":"no id"}"#.utf8)))
    }

    // MARK: - Paths

    func testClassifiesTheThreeStoreShapes() {
        let account = "\(root)/138823c7/6d07c476"
        XCTAssertEqual(
            CoworkPaths.classify(path: "\(account)/\(sessionId).json", root: root),
            .init(kind: .metadata, sessionId: sessionId, accountDirectory: account)
        )
        XCTAssertEqual(
            CoworkPaths.classify(path: "\(account)/\(sessionId)/audit.jsonl", root: root),
            .init(kind: .audit, sessionId: sessionId, accountDirectory: account)
        )
        XCTAssertEqual(
            CoworkPaths.classify(
                path: "\(account)/\(sessionId)/.claude/projects/-sessions-bold-inspiring-tesla/d0a5dc71.jsonl",
                root: root
            ),
            .init(kind: .transcript, sessionId: sessionId, accountDirectory: account)
        )
    }

    func testIgnoresEverythingElseUnderTheStore() {
        let account = "\(root)/138823c7/6d07c476"
        let ignored = [
            "\(account)/\(sessionId)/.claude/debug/d0a5dc71.txt",
            "\(account)/\(sessionId)/.claude/projects/-sessions-x/d0a5dc71/subagents/agent-ab0da74.jsonl",
            "\(account)/\(sessionId)/uploads/file.png",
            "\(account)/\(sessionId).json.tmp-1234",
            "\(account)/scheduled-tasks.json",
            "\(account)/agent/\(sessionId).json",
            "\(root)/skills-plugin/6d07c476/046b191a/manifest.json",
            "\(root)/skills-plugin/a/local_abc.json",
            "\(root)/138823c7/\(sessionId).json",
            "/tmp/elsewhere/a/b/\(sessionId).json",
            "\(root)-other/a/b/\(sessionId).json",
        ]
        for path in ignored {
            XCTAssertNil(CoworkPaths.classify(path: path, root: root), path)
        }
    }

    func testSessionIdValidation() {
        XCTAssertTrue(CoworkPaths.isValidSessionId(sessionId))
        XCTAssertTrue(CoworkPaths.isValidSessionId("local_ditto_abc_g1"))
        XCTAssertFalse(CoworkPaths.isValidSessionId("local_"))
        XCTAssertFalse(CoworkPaths.isValidSessionId("local_a.b"))
        XCTAssertFalse(CoworkPaths.isValidSessionId("local_a/b"))
        XCTAssertFalse(CoworkPaths.isValidSessionId("session_abc"))
        XCTAssertFalse(CoworkPaths.isValidSessionId("local_" + String(repeating: "a", count: 129)))
    }

    func testTranscriptPathScansProjectSlugs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-transcript-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let slugDir = "\(dir)/.claude/projects/-sessions-bold-inspiring-tesla"
        try FileManager.default.createDirectory(atPath: slugDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: "\(dir)/.claude/projects/-sessions-other",
            withIntermediateDirectories: true
        )
        let transcript = "\(slugDir)/d0a5dc71.jsonl"
        FileManager.default.createFile(atPath: transcript, contents: Data())

        XCTAssertEqual(CoworkPaths.transcriptPath(sessionDirectory: dir, cliSessionId: "d0a5dc71"), transcript)
        XCTAssertNil(CoworkPaths.transcriptPath(sessionDirectory: dir, cliSessionId: "missing"))
        XCTAssertNil(CoworkPaths.transcriptPath(sessionDirectory: dir, cliSessionId: "../escape"))
    }

    // MARK: - Policy

    func testLaunchPolicyOnlyVouchesForFreshTrackableSessionsWithTurns() {
        let now = Date()
        let fresh = now.addingTimeInterval(-60)
        let base = CoworkSessionMetadata(sessionId: sessionId)

        XCTAssertTrue(CoworkSessionPolicy.shouldSurfaceOnLaunch(
            metadata: base, auditSize: 120, lastActivity: fresh, now: now))

        var archived = base
        archived.isArchived = true
        XCTAssertFalse(CoworkSessionPolicy.shouldSurfaceOnLaunch(
            metadata: archived, auditSize: 120, lastActivity: fresh, now: now), "archived")

        XCTAssertFalse(CoworkSessionPolicy.shouldSurfaceOnLaunch(
            metadata: base, auditSize: 0, lastActivity: fresh, now: now), "zero turns")

        XCTAssertFalse(CoworkSessionPolicy.shouldSurfaceOnLaunch(
            metadata: base, auditSize: 120,
            lastActivity: now.addingTimeInterval(-CoworkSessionPolicy.launchFreshness - 1), now: now), "stale")

        XCTAssertFalse(CoworkSessionPolicy.shouldSurfaceOnLaunch(
            metadata: base, auditSize: 120, lastActivity: nil, now: now), "no activity evidence")

        for hidden in ["agent", "dispatch_child", "radar"] {
            var metadata = base
            metadata.sessionType = hidden
            XCTAssertFalse(CoworkSessionPolicy.shouldSurfaceOnLaunch(
                metadata: metadata, auditSize: 120, lastActivity: fresh, now: now), hidden)
        }
        for shown in ["chat", "scheduled"] {
            var metadata = base
            metadata.sessionType = shown
            XCTAssertTrue(CoworkSessionPolicy.shouldSurfaceOnLaunch(
                metadata: metadata, auditSize: 120, lastActivity: fresh, now: now), shown)
        }
    }

    func testLastActivityTakesNewestEvidence() {
        let saved = Date(timeIntervalSince1970: 1_000)
        let appended = Date(timeIntervalSince1970: 2_000)
        let metadata = CoworkSessionMetadata(sessionId: sessionId, lastActivityAt: saved)
        XCTAssertEqual(CoworkSessionPolicy.lastActivity(metadata: metadata, auditModifiedAt: appended), appended)
        XCTAssertEqual(CoworkSessionPolicy.lastActivity(metadata: metadata, auditModifiedAt: nil), saved)
        XCTAssertNil(CoworkSessionPolicy.lastActivity(
            metadata: CoworkSessionMetadata(sessionId: sessionId), auditModifiedAt: nil))
    }

    func testHookSessionShadowsTheStoreCard() {
        XCTAssertTrue(CoworkSessionPolicy.isShadowedByHookSession(
            cliSessionId: "d0a5", existingSessionKeys: ["d0a5", "cowork:\(sessionId)"]))
        XCTAssertFalse(CoworkSessionPolicy.isShadowedByHookSession(
            cliSessionId: "d0a5", existingSessionKeys: ["cowork:\(sessionId)"]))
        XCTAssertFalse(CoworkSessionPolicy.isShadowedByHookSession(
            cliSessionId: nil, existingSessionKeys: ["d0a5"]))
    }

    func testDeepLinkTargetsTheCoworkRouteOnlyForValidIds() {
        XCTAssertEqual(
            CoworkSessionPolicy.deepLinkURL(sessionId: sessionId)?.absoluteString,
            "claude://claude.ai/cowork/\(sessionId)"
        )
        XCTAssertNil(CoworkSessionPolicy.deepLinkURL(sessionId: "local_../settings"))
        XCTAssertNil(CoworkSessionPolicy.deepLinkURL(sessionId: "cse_abc"))
    }
}
