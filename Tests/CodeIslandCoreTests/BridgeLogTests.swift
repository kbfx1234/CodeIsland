import Darwin
import XCTest
@testable import CodeIslandCore

/// The bridge's log: a line per hook that says what it was, never what it
/// said; whole payloads only under CODEISLAND_DEBUG=1; bounded by moving to
/// `.1`. Against a scratch folder of the test's, never /tmp's shared log.
final class BridgeLogTests: XCTestCase {
    private var scratch: String!
    private var log: String { scratch + "/bridge.log" }

    override func setUpWithError() throws {
        scratch = NSTemporaryDirectory() + "ci-bridge-log-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func mode(_ path: String) throws -> mode_t {
        try XCTUnwrap(SocketPath.lstat(path), path).st_mode & 0o777
    }

    // MARK: - Where and what

    func testTheLogIsInTmpUnlessMoved() {
        XCTAssertEqual(BridgeLog(environment: [:]).path, "/tmp/codeisland-bridge.log")
        XCTAssertEqual(BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": ""]).path, "/tmp/codeisland-bridge.log")
        XCTAssertEqual(BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log]).path, log)
    }

    func testPayloadsAreLoggedOnlyUnderDebug() {
        XCTAssertFalse(BridgeLog(environment: [:]).logsPayloads)
        XCTAssertFalse(BridgeLog(environment: ["CODEISLAND_DEBUG": "0"]).logsPayloads)
        XCTAssertFalse(BridgeLog(environment: ["CODEISLAND_DEBUG": ""]).logsPayloads)
        XCTAssertTrue(BridgeLog(environment: ["CODEISLAND_DEBUG": "1"]).logsPayloads)

        BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log]).payload("raw input: SECRET")
        XCTAssertEqual(read(log), "")
        BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log, "CODEISLAND_DEBUG": "1"]).payload("raw input: SECRET")
        XCTAssertTrue(read(log).hasSuffix("] raw input: SECRET\n"), read(log))
    }

    func testAHookLineNamesTheHookNotItsContent() {
        let line = BridgeLog.hookLine(
            eventName: "PreToolUse",
            normalizedEventName: "PreToolUse",
            source: "codex",
            sessionId: "019a-session",
            toolName: "Bash",
            payloadKeys: ["tool_input", "session_id", "hook_event_name", "cwd", "tool_name"],
            blocking: true
        )
        XCTAssertEqual(
            line,
            "hook event=PreToolUse normalized=PreToolUse source=codex session=019a-session tool=Bash keys=cwd,hook_event_name,session_id,tool_input,tool_name blocking=true"
        )
        let unnamed = BridgeLog.hookLine(
            eventName: "Stop", normalizedEventName: "Stop", source: nil, sessionId: "s",
            toolName: nil, payloadKeys: [], blocking: false
        )
        XCTAssertEqual(unnamed, "hook event=Stop normalized=Stop source=- session=s tool=- keys= blocking=false")
    }

    func testAHooksOwnTextStaysOnOneLineAndShort() {
        XCTAssertEqual(BridgeLog.field("a\nforged line\u{1B}]52;c;x\u{07}\u{9B}"), "a_forged_line_]52;c;x__")
        XCTAssertEqual(BridgeLog.field(String(repeating: "s", count: 300)), String(repeating: "s", count: 128) + "…")
        let keys = (0..<50).map { "k\(String(format: "%02d", $0))" }
        XCTAssertEqual(BridgeLog.keyList(keys), keys.prefix(40).joined(separator: ",") + ",…")
    }

    // MARK: - Bounded

    func testALogPastItsCapMovesToDotOneReplacingTheOneBefore() throws {
        let bridgeLog = BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log], maxBytes: 100)
        XCTAssertTrue(FileManager.default.createFile(atPath: log + ".1", contents: Data("oldest\n".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: log, contents: Data(String(repeating: "x", count: 90).utf8)))
        XCTAssertEqual(chmod(log, 0o600), 0)

        bridgeLog.note("next")
        XCTAssertEqual(read(log + ".1"), String(repeating: "x", count: 90))
        XCTAssertEqual(try mode(log + ".1"), 0o600)
        XCTAssertTrue(read(log).hasSuffix("] next\n"), read(log))
        XCTAssertEqual(try mode(log), 0o600)
    }

    func testALogUnderItsCapIsAppendedTo() {
        let bridgeLog = BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log], maxBytes: 1000)
        bridgeLog.note("one")
        bridgeLog.note("two")
        XCTAssertEqual(read(log).components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log + ".1"))
    }

    func testALineLongerThanTheCapStillLands() {
        let bridgeLog = BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log], maxBytes: 10)
        bridgeLog.note(String(repeating: "y", count: 50))
        XCTAssertTrue(read(log).contains(String(repeating: "y", count: 50)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log + ".1"), "nothing older to keep")
    }

    func testADotOneSymlinkIsReplacedNotWrittenThrough() throws {
        let target = scratch + "/zshrc"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("untouched\n".utf8)))
        try FileManager.default.createSymbolicLink(atPath: log + ".1", withDestinationPath: target)
        XCTAssertTrue(FileManager.default.createFile(atPath: log, contents: Data(String(repeating: "x", count: 90).utf8)))

        BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log], maxBytes: 100).note("next")
        XCTAssertEqual(read(target), "untouched\n")
        XCTAssertEqual(try XCTUnwrap(SocketPath.lstat(log + ".1")).st_mode & S_IFMT, S_IFREG)
    }

    func testWhenDotOneCannotBeReplacedTheLogStartsOverInPlace() throws {
        // A folder with something in it: rename cannot replace it, as it
        // cannot replace another user's file in sticky /tmp.
        XCTAssertEqual(mkdir(log + ".1", 0o700), 0)
        XCTAssertTrue(FileManager.default.createFile(atPath: log + ".1/kept", contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: log, contents: Data(String(repeating: "x", count: 90).utf8)))

        BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log], maxBytes: 100).note("next")
        let logged = read(log)
        XCTAssertFalse(logged.contains("xxxx"), logged)
        XCTAssertTrue(logged.hasSuffix("] next\n"), logged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log + ".1/kept"))
    }

    // MARK: - Whose

    func testNothingIsWrittenThroughASymlinkOrAHardLinkOrToAFIFO() throws {
        let target = scratch + "/zshrc"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("untouched\n".utf8)))
        let bridgeLog = BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log], maxBytes: 100)

        try FileManager.default.createSymbolicLink(atPath: log, withDestinationPath: target)
        bridgeLog.note("via symlink")
        try FileManager.default.removeItem(atPath: log)

        try FileManager.default.linkItem(atPath: target, toPath: log)
        bridgeLog.note("via hard link")
        try FileManager.default.removeItem(atPath: log)
        XCTAssertEqual(read(target), "untouched\n")

        XCTAssertEqual(mkfifo(log, 0o600), 0)
        bridgeLog.note("into a FIFO")  // returns rather than waiting for a reader
    }

    func testALogOthersCouldReadIsClosedToThem() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: log, contents: Data("earlier\n".utf8)))
        XCTAssertEqual(chmod(log, 0o644), 0)
        BridgeLog(environment: ["CODEISLAND_BRIDGE_LOG": log]).note("next")
        XCTAssertEqual(try mode(log), 0o600)
        XCTAssertTrue(read(log).hasPrefix("earlier\n"))
    }
}
