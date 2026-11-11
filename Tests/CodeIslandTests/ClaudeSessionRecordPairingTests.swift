import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Claude Code keeps a record per running session in `<config dir>/sessions/<pid>.json`
/// (pid, sessionId, cwd, procStart, …). With several sessions in one cwd, discovery
/// paired transcripts to processes by recency alone: on a real Mac two sessions in ~
/// (pids 6981 and 64559) had their records say 6981 → c4a286da and 64559 → fcfa4dcd,
/// yet discovery bound c4a286da to 64559, so that card was watched on the other
/// session's CLI. Fixtures here are synthetic: no transcript content.
final class ClaudeSessionRecordPairingTests: XCTestCase {
    private var root: String!
    private let cwd = "/Users/u/project"
    private var now = Date()
    private var p1: ClaudeDiscovery.ClaudeDiscoveryProcess!
    private var p2: ClaudeDiscovery.ClaudeDiscoveryProcess!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-config-\(UUID().uuidString)").path
        now = Date()
        // Process start times are whole seconds (proc_bsdinfo).
        p1 = .init(pid: 101, cwd: cwd, startTime: Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 3600).rounded(.down)))
        p2 = .init(pid: 102, cwd: cwd, startTime: Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 1800).rounded(.down)))
        // Two fresh transcripts in the shared project dir; B is the newest.
        try writeTranscript("aaaaaaaa-0000-4000-8000-000000000001", modified: now.addingTimeInterval(-60))
        try writeTranscript("bbbbbbbb-0000-4000-8000-000000000002", modified: now.addingTimeInterval(-30))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private let sessionA = "aaaaaaaa-0000-4000-8000-000000000001"
    private let sessionB = "bbbbbbbb-0000-4000-8000-000000000002"

    private func writeTranscript(_ sessionId: String, modified: Date) throws {
        let dir = "\(root!)/projects/\(cwd.claudeProjectDirEncoded())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(sessionId).jsonl"
        let line = #"{"type":"user","message":{"role":"user","content":"<prompt>"}}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    private static func procStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private func writeRecord(pid: pid_t, json: String) throws {
        let dir = "\(root!)/sessions"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try json.write(
            toFile: ClaudeConfigPaths.sessionRecordPath(configDir: root, pid: pid),
            atomically: true, encoding: .utf8
        )
    }

    private func writeRecord(for process: ClaudeDiscovery.ClaudeDiscoveryProcess, sessionId: String, procStart: Date? = nil) throws {
        let start = Self.procStart(procStart ?? process.startTime!)
        try writeRecord(pid: process.pid, json: """
            {"pid":\(process.pid),"sessionId":"\(sessionId)","cwd":"\(cwd)","procStart":"\(start)",\
            "kind":"interactive","entrypoint":"cli","status":"idle","version":"2.1.309"}
            """)
    }

    private let cliArgv = ["claude", "--dangerously-skip-permissions"]

    /// discovery's pairing, over the fixture root, with the live record reader
    /// (only argv is faked: the processes are fictional).
    private func discover(
        _ processes: [ClaudeDiscovery.ClaudeDiscoveryProcess],
        argv: [String]? = nil
    ) -> [pid_t: String] {
        let sessions = ClaudeDiscovery.claudeSessions(
            for: processes,
            root: root,
            claimed: [],
            transcripts: { ClaudeDiscovery.claudeTranscriptFiles(in: $0, fm: .default) },
            recordedSessionId: { process in
                ClaudeDiscovery.recordedSessionId(for: process, root: self.root, arguments: { _ in argv ?? self.cliArgv })
            }
        )
        var pairs: [pid_t: String] = [:]
        for session in sessions {
            if let pid = session.pid { pairs[pid] = session.sessionId }
        }
        return pairs
    }

    // MARK: - No registry: exactly today's behaviour

    func testWithoutRecordsTheRecencyMatchIsUnchanged() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root!)/sessions"))
        // Today: the first process takes the newest fresh transcript, and the
        // second finds that one taken and gets nothing.
        XCTAssertEqual(discover([p1, p2]), [p1.pid: sessionB])
        XCTAssertEqual(discover([p2, p1]), [p2.pid: sessionB])
        XCTAssertNil(ClaudeDiscovery.recordedSessionId(for: p1, root: root))
    }

    // MARK: - Records pair each process with its own session

    func testTwoSessionsInOneCwdArePairedByTheirRecords() throws {
        try writeRecord(for: p1, sessionId: sessionA)
        try writeRecord(for: p2, sessionId: sessionB)
        XCTAssertEqual(discover([p1, p2]), [p1.pid: sessionA, p2.pid: sessionB])
        XCTAssertEqual(discover([p2, p1]), [p1.pid: sessionA, p2.pid: sessionB])
    }

    func testAProcessWithoutARecordCannotTakeASessionRecordedAsAnothers() throws {
        try writeRecord(for: p2, sessionId: sessionB)
        // p1 (no record) would have taken B, the newest: it is p2's.
        XCTAssertEqual(discover([p1, p2]), [p2.pid: sessionB])
    }

    // MARK: - Records that are not this process's are ignored

    func testARecordLeftByAnEarlierProcessWithTheSamePidIsIgnored() throws {
        // Same pid, but procStart is an hour before this process started.
        try writeRecord(for: p1, sessionId: sessionA, procStart: p1.startTime!.addingTimeInterval(-3600))
        XCTAssertNil(ClaudeDiscovery.recordedSessionId(for: p1, root: root, arguments: { _ in self.cliArgv }))
        XCTAssertEqual(discover([p1]), [p1.pid: sessionB], "the recency match, as with no record")
    }

    func testAGarbageRecordIsIgnored() throws {
        try writeRecord(pid: p1.pid, json: "{\"pid\": 101, \"sessionId\": ")
        XCTAssertNil(ClaudeDiscovery.recordedSessionId(for: p1, root: root, arguments: { _ in self.cliArgv }))
        XCTAssertEqual(discover([p1, p2]), [p1.pid: sessionB])

        try writeRecord(pid: p1.pid, json: "[1, 2, 3]")
        XCTAssertEqual(discover([p1, p2]), [p1.pid: sessionB])
    }

    func testAnOversizedRecordIsIgnored() throws {
        let padding = String(repeating: "x", count: ClaudeDiscovery.sessionRecordByteLimit)
        try writeRecord(pid: p1.pid, json: """
            {"pid":101,"sessionId":"\(sessionA)","procStart":"\(Self.procStart(p1.startTime!))","pad":"\(padding)"}
            """)
        XCTAssertNil(ClaudeDiscovery.recordedSessionId(for: p1, root: root, arguments: { _ in self.cliArgv }))
        XCTAssertEqual(discover([p1]), [p1.pid: sessionB])
    }

    func testARecordNamingAnotherPidIsIgnored() throws {
        try writeRecord(pid: p1.pid, json: """
            {"pid":999,"sessionId":"\(sessionA)","procStart":"\(Self.procStart(p1.startTime!))"}
            """)
        XCTAssertEqual(discover([p1]), [p1.pid: sessionB])
    }

    func testARecordWithoutProcStartIsIgnored() throws {
        try writeRecord(pid: p1.pid, json: #"{"pid":101,"sessionId":"aaaaaaaa-0000-4000-8000-000000000001"}"#)
        XCTAssertNil(ClaudeDiscovery.recordedSessionId(for: p1, root: root, arguments: { _ in self.cliArgv }))
    }

    func testARecordIsNotUsedForAProcessThatIsNotTheCLI() throws {
        try writeRecord(for: p1, sessionId: sessionA)
        XCTAssertNil(ClaudeDiscovery.recordedSessionId(
            for: p1, root: root, arguments: { _ in ["ugrep", "-G", "--line-buffered", "<pattern>"] }
        ))
        XCTAssertNil(ClaudeDiscovery.recordedSessionId(for: p1, root: root, arguments: { _ in nil }), "argv unreadable")
    }

    func testARecordWhoseSessionIsNotFreshShowsNothingRatherThanAnotherSession() throws {
        try writeTranscript(sessionA, modified: now.addingTimeInterval(-3000))
        try writeRecord(for: p1, sessionId: sessionA)
        try writeRecord(for: p2, sessionId: sessionB)
        XCTAssertEqual(discover([p1, p2]), [p2.pid: sessionB])
    }

    // MARK: - procStart

    func testRecordedProcessStartIsReadAsUTC() {
        XCTAssertEqual(
            ClaudeDiscovery.parseRecordedProcessStart("Fri Oct 23 00:59:52 2026")?.timeIntervalSince1970,
            1_792_717_192
        )
        XCTAssertEqual(
            ClaudeDiscovery.parseRecordedProcessStart("Sat Oct  3 01:02:03 2026")?.timeIntervalSince1970,
            1_790_989_323
        )
        XCTAssertNil(ClaudeDiscovery.parseRecordedProcessStart("yesterday"))
    }
}
