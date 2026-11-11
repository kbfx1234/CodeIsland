import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Session-store watcher against a fake store in a temp dir. FSEvents timing is
/// taken out of the loop: the stream is disabled and batches are fed through
/// `ingestAndWait`, which runs the exact code the stream callback runs.
final class CoworkSessionWatcherTests: XCTestCase {

    private final class OutputRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [CoworkSessionWatcher.Output] = []

        func record(_ output: CoworkSessionWatcher.Output) {
            lock.lock()
            outputs.append(output)
            lock.unlock()
        }

        func drain() -> [CoworkSessionWatcher.Output] {
            lock.lock()
            defer { outputs.removeAll(); lock.unlock() }
            return outputs
        }
    }

    private var root: String!
    private var account: String!
    private let recorder = OutputRecorder()
    private var watcher: CoworkSessionWatcher?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-store-\(UUID().uuidString)")
            .appendingPathComponent("local-agent-mode-sessions").path
        account = "\(root!)/138823c7-c191-436d-bd76-e005d8a468ff/6d07c476-6dc2-4b9a-9dfe-ac729e875ad8"
        try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    // MARK: - Fake store

    private func id(_ n: Int) -> String {
        String(format: "local_00000000-0000-0000-0000-%012d", n)
    }

    @discardableResult
    private func writeSession(
        _ n: Int,
        archived: Bool = false,
        sessionType: String? = nil,
        auditLines: [String]? = nil,
        modifiedAgo: TimeInterval = 0
    ) throws -> String {
        let sessionId = id(n)
        let typeField = sessionType.map { #","sessionType":""# + $0 + #"""# } ?? ""
        let json = #"{"sessionId":""# + sessionId + #"","cliSessionId":"cli-"# + "\(n)" + #"","cwd":"/sessions/vm-"# + "\(n)" +
            #"","userSelectedFolders":["/Users/alice/p"# + "\(n)" + #""],"lastActivityAt":1000,"isArchived":"# +
            "\(archived)" + #","title":"Task "# + "\(n)" + #"""# + typeField + "}"
        let metadataPath = "\(account!)/\(sessionId).json"
        try json.write(toFile: metadataPath, atomically: true, encoding: .utf8)
        if let auditLines {
            try FileManager.default.createDirectory(atPath: "\(account!)/\(sessionId)", withIntermediateDirectories: true)
            let body = auditLines.map { $0 + "\n" }.joined()
            try body.write(toFile: auditPath(n), atomically: false, encoding: .utf8)
        }
        if modifiedAgo > 0 {
            let date = Date(timeIntervalSinceNow: -modifiedAgo)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: metadataPath)
            if auditLines != nil {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: auditPath(n))
            }
        }
        return sessionId
    }

    private func auditPath(_ n: Int) -> String {
        "\(account!)/\(id(n))/audit.jsonl"
    }

    private func append(_ n: Int, _ lines: [String]) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: auditPath(n)))
        handle.seekToEndOfFile()
        handle.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        try handle.close()
    }

    private func startWatcher() -> [CoworkSessionWatcher.SessionUpdate] {
        let recorder = self.recorder
        let watcher = CoworkSessionWatcher(rootPath: root, usesFileSystemEvents: false) { output in
            recorder.record(output)
        }
        self.watcher = watcher
        watcher.startAndWait()
        let outputs = recorder.drain()
        guard outputs.count == 1, case .launchSnapshot(let snapshot) = outputs[0] else {
            XCTFail("expected exactly one launch snapshot, got \(outputs)")
            return []
        }
        return snapshot
    }

    private func ingest(_ paths: [String]) -> (updates: [CoworkSessionWatcher.SessionUpdate], removed: [String]) {
        watcher?.ingestAndWait(paths: paths)
        var updates: [CoworkSessionWatcher.SessionUpdate] = []
        var removed: [String] = []
        for output in recorder.drain() {
            switch output {
            case .updates(let batch): updates += batch
            case .removed(let ids): removed += ids
            case .launchSnapshot: XCTFail("launch snapshot is delivered once")
            }
        }
        return (updates, removed)
    }

    private let turn = [
        CoworkAuditFixture.userPrompt,
        CoworkAuditFixture.assistantReply,
        CoworkAuditFixture.resultSuccess,
    ]

    // MARK: - Launch

    func testLaunchSnapshotVouchesOnlyForFreshTrackableSessionsWithTurns() throws {
        try writeSession(1, auditLines: turn)                                   // fresh, finished
        try writeSession(2, auditLines: [CoworkAuditFixture.userPrompt])       // fresh, mid-turn
        try writeSession(3, auditLines: turn, modifiedAgo: 3 * 3600)            // stale
        try writeSession(4, archived: true, auditLines: turn)                   // archived
        try writeSession(5)                                                     // zero turns
        try writeSession(6, sessionType: "dispatch_child", auditLines: turn)    // hidden
        try writeSession(7, sessionType: "chat", auditLines: turn)              // local chat

        let snapshot = startWatcher()
        let byId = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.sessionId, $0) })
        XCTAssertEqual(Set(byId.keys), [id(1), id(2), id(7)])
        XCTAssertEqual(byId[id(1)]?.audit.phase, .idle)
        XCTAssertEqual(byId[id(2)]?.audit.phase, .processing, "state rebuilt from the audit tail")
        XCTAssertEqual(byId[id(1)]?.isLive, false)
        XCTAssertEqual(byId[id(1)]?.metadata.title, "Task 1")
    }

    func testMissingStoreStillReportsAnEmptySnapshot() throws {
        try FileManager.default.removeItem(atPath: root)
        XCTAssertEqual(startWatcher(), [])
    }

    // MARK: - Live activity

    func testAppendedTurnOnAHistoricalSessionIsLive() throws {
        try writeSession(1, auditLines: turn, modifiedAgo: 3 * 3600)
        XCTAssertEqual(startWatcher(), [])

        // History is not replayed: only what is appended after launch counts.
        try append(1, [CoworkAuditFixture.userPrompt])
        var result = ingest([auditPath(1)])
        var update = try XCTUnwrap(result.updates.first)
        XCTAssertTrue(update.isLive)
        XCTAssertEqual(update.promptsStarted, 1)
        XCTAssertEqual(update.turnsCompleted, 0)
        XCTAssertEqual(update.audit.phase, .processing)

        try append(1, [CoworkAuditFixture.assistantReply, CoworkAuditFixture.resultSuccess])
        result = ingest([auditPath(1)])
        update = try XCTUnwrap(result.updates.first)
        XCTAssertEqual(update.turnsCompleted, 1)
        XCTAssertEqual(update.promptsStarted, 0)
        XCTAssertEqual(update.audit.phase, .idle)
    }

    func testSessionCreatedAfterLaunchIsReadFromTheStart() throws {
        XCTAssertEqual(startWatcher(), [])
        try writeSession(9, auditLines: [CoworkAuditFixture.userPrompt])
        let update = try XCTUnwrap(ingest(["\(account!)/\(id(9)).json", auditPath(9)]).updates.first)
        XCTAssertEqual(update.sessionId, id(9))
        XCTAssertTrue(update.isLive)
        XCTAssertEqual(update.audit.lastPrompt, "list the installers")
    }

    func testLineSplitAcrossTwoWritesIsReadOnce() throws {
        try writeSession(1, auditLines: [])
        _ = startWatcher()
        let line = CoworkAuditFixture.userPrompt
        let cut = line.index(line.startIndex, offsetBy: 20)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: auditPath(1)))
        handle.seekToEndOfFile()
        handle.write(Data(line[..<cut].utf8))
        XCTAssertTrue(ingest([auditPath(1)]).updates.isEmpty, "half a line is not an event")
        handle.write(Data((String(line[cut...]) + "\n").utf8))
        try handle.close()
        let update = try XCTUnwrap(ingest([auditPath(1)]).updates.first)
        XCTAssertEqual(update.promptsStarted, 1)
    }

    func testBookkeepingLinesAfterATurnAreNotLive() throws {
        try writeSession(1, auditLines: turn)
        XCTAssertEqual(startWatcher().count, 1)
        // Written after the turn ended — possibly after the idle sweep already
        // collected the card, which the watcher cannot know.
        try append(1, [
            #"{"type":"system","subtype":"permission_auto_approved","session_id":"d0a5","tool_name":"Read","source":"session_rule_cache"}"#,
            #"{"type":"system","subtype":"compact_boundary","session_id":"d0a5"}"#,
        ])
        XCTAssertTrue(ingest([auditPath(1)]).updates.isEmpty, "nothing to report, nothing to reopen")

        // A real turn still is.
        try append(1, [CoworkAuditFixture.userPrompt])
        let update = try XCTUnwrap(ingest([auditPath(1)]).updates.first)
        XCTAssertTrue(update.isLive)
        XCTAssertEqual(update.promptsStarted, 1)
    }

    func testPermissionRequestIsForwarded() throws {
        try writeSession(1, auditLines: [CoworkAuditFixture.userPrompt])
        _ = startWatcher()
        try append(1, [CoworkAuditFixture.permissionRequest(id: "r", tool: "Bash", input: #"{"command":"rm x"}"#)])
        let update = try XCTUnwrap(ingest([auditPath(1)]).updates.first)
        XCTAssertEqual(update.permissionsRequested, 1)
        XCTAssertEqual(update.audit.phase, .waitingApproval)
    }

    // MARK: - Metadata, transcript, deletion

    func testMetadataChangeOfAnUnsurfacedSessionIsSilent() throws {
        try writeSession(1, auditLines: turn, modifiedAgo: 3 * 3600)
        _ = startWatcher()
        try writeSession(1, archived: true, auditLines: nil)
        XCTAssertTrue(ingest(["\(account!)/\(id(1)).json"]).updates.isEmpty)
    }

    func testArchivingASurfacedSessionIsForwarded() throws {
        try writeSession(1, auditLines: turn)
        XCTAssertEqual(startWatcher().count, 1)
        try writeSession(1, archived: true)
        let update = try XCTUnwrap(ingest(["\(account!)/\(id(1)).json"]).updates.first)
        XCTAssertTrue(update.metadata.isArchived)
        XCTAssertFalse(update.isLive)
    }

    func testTranscriptPathIsResolvedOnceTheCLIWritesIt() throws {
        try writeSession(1, auditLines: turn)
        XCTAssertNil(startWatcher().first?.transcriptPath)

        let slugDir = "\(account!)/\(id(1))/.claude/projects/-sessions-vm-1"
        try FileManager.default.createDirectory(atPath: slugDir, withIntermediateDirectories: true)
        let transcript = "\(slugDir)/cli-1.jsonl"
        FileManager.default.createFile(atPath: transcript, contents: Data("{}\n".utf8))

        let update = try XCTUnwrap(ingest([transcript]).updates.first)
        XCTAssertEqual(update.transcriptPath, transcript)
        // Later transcript writes are not worth an update.
        XCTAssertTrue(ingest([transcript]).updates.isEmpty)
    }

    func testDeletedSurfacedSessionIsReportedRemoved() throws {
        try writeSession(1, auditLines: turn)
        XCTAssertEqual(startWatcher().count, 1)
        try FileManager.default.removeItem(atPath: "\(account!)/\(id(1)).json")
        try FileManager.default.removeItem(atPath: "\(account!)/\(id(1))")
        XCTAssertEqual(ingest(["\(account!)/\(id(1)).json"]).removed, [id(1)])
    }

    func testDroppedEventsTriggerAFullRescan() throws {
        try writeSession(1, auditLines: turn, modifiedAgo: 3 * 3600)
        _ = startWatcher()
        try append(1, [CoworkAuditFixture.userPrompt])
        watcher?.ingestAndWait(paths: [], needsRescan: true)
        let updates = recorder.drain().compactMap { output -> [CoworkSessionWatcher.SessionUpdate]? in
            if case .updates(let batch) = output { return batch }
            return nil
        }.flatMap { $0 }
        XCTAssertEqual(updates.map(\.sessionId), [id(1)])
        XCTAssertEqual(updates.first?.promptsStarted, 1)
    }

    /// The one test that goes through a real FSEventStream: the temp dir sits
    /// behind the /var → /private/var symlink, so it also covers FSEvents
    /// reporting resolved paths.
    func testFileSystemEventsDriveUpdatesEndToEnd() throws {
        try writeSession(1, auditLines: turn, modifiedAgo: 3 * 3600)
        let live = expectation(description: "live update from FSEvents")
        live.assertForOverFulfill = false
        let watcher = CoworkSessionWatcher(rootPath: root, latency: 0.05) { output in
            if case .updates(let updates) = output, updates.contains(where: { $0.promptsStarted == 1 }) {
                live.fulfill()
            }
        }
        self.watcher = watcher
        watcher.startAndWait()
        // The stream only reports changes after it is armed.
        Thread.sleep(forTimeInterval: 0.3)
        try append(1, [CoworkAuditFixture.userPrompt])
        wait(for: [live], timeout: 10)
    }

    func testUnrelatedPathsCostNothing() throws {
        try writeSession(1, auditLines: turn)
        _ = startWatcher()
        let result = ingest([
            "\(account!)/\(id(1))/.claude/debug/cli-1.txt",
            "\(account!)/\(id(1))/.claude/statsig/statsig.cached.evaluations",
            "\(root!)/skills-plugin/x/y/manifest.json",
        ])
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertTrue(result.removed.isEmpty)
    }
}
