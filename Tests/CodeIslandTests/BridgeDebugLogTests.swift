import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The bridge's log says what each hook was, never what it said: the whole
/// payload only under CODEISLAND_DEBUG=1. Its default path is a predictable
/// name in /tmp, which another user can take first, so the real bridge
/// writes it only as a regular file of this user's that nothing else links
/// to, never through a symlink, readable by nobody else, and moves it to
/// `.1` past ~5 MB. Against a stand-in socket and a log path of the test's,
/// never the shared ones.
final class BridgeDebugLogTests: XCTestCase {
    private var scratch: String!
    private var log: String { scratch + "/bridge.log" }

    override func setUpWithError() throws {
        scratch = "/tmp/ci-sown-log-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    /// Runs the real bridge on a prompt event, delivered to a stand-in island;
    /// fails unless it exits within 10 s and the event arrives.
    private func runBridge(debug: Bool = false) throws {
        let bridge = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("codeisland-bridge")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else {
            throw XCTSkip("codeisland-bridge not built next to the test bundle")
        }
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data("{}".utf8)))
        let process = Process()
        process.executableURL = bridge
        process.arguments = ["--source", "claude"]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CODEISLAND_SOCKET_PATH": server.path,
            "CODEISLAND_BRIDGE_LOG": log,
        ].merging(debug ? ["CODEISLAND_DEBUG": "1"] : [:]) { $1 }
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"sown-log","cwd":"/tmp/SECRET-CWD","prompt":"SECRET-PROMPT"}"#
        try? stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try? stdin.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            XCTFail("the bridge hung on its log")
        }
        XCTAssertTrue(server.waitUntilServed(timeout: 5), "the event must still be delivered")
    }

    private func mode(_ path: String) throws -> mode_t {
        try XCTUnwrap(SocketPath.lstat(path)).st_mode & 0o777
    }

    private let hookLine = "hook event=UserPromptSubmit normalized=UserPromptSubmit source=claude session=sown-log tool=- keys=cwd,hook_event_name,prompt,session_id blocking=false"

    // MARK: - What it holds

    func testAHookLeavesWhatItWasNotWhatItSaid() throws {
        try runBridge()
        let logged = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(logged.contains(hookLine), logged)
        XCTAssertFalse(logged.contains("SECRET"), "a prompt or path must not reach the log: \(logged)")
    }

    func testDebugLogsTheWholePayloadToo() throws {
        try runBridge(debug: true)
        let logged = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(logged.contains(hookLine), logged)
        XCTAssertTrue(logged.contains("SECRET-PROMPT"), logged)
    }

    func testALogPastItsCapMovesToDotOneAndStartsOver() throws {
        let old = String(repeating: "x", count: BridgeLog.defaultMaxBytes)
        XCTAssertTrue(FileManager.default.createFile(atPath: log, contents: Data(old.utf8)))
        XCTAssertEqual(chmod(log, 0o600), 0)
        try runBridge()
        let rotated = log + ".1"
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: rotated)[.size] as? Int, old.utf8.count)
        XCTAssertEqual(try mode(rotated), 0o600)
        let fresh = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(fresh.contains(hookLine), fresh)
        XCTAssertLessThan(fresh.utf8.count, 4096)
        XCTAssertEqual(try mode(log), 0o600)
    }

    // MARK: - Who can read it

    func testTheLogIsReadableByThisUserAlone() throws {
        try runBridge()
        XCTAssertTrue(try String(contentsOfFile: log, encoding: .utf8).contains(hookLine))
        XCTAssertEqual(try mode(log), 0o600)
    }

    func testALogOthersCouldReadIsClosedToThem() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: log, contents: Data("earlier\n".utf8)))
        XCTAssertEqual(chmod(log, 0o644), 0)
        try runBridge()
        XCTAssertEqual(try mode(log), 0o600)
        let logged = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(logged.hasPrefix("earlier\n") && logged.contains(hookLine), logged)
    }

    func testNothingIsWrittenThroughASymlink() throws {
        let target = scratch + "/zshrc"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("untouched\n".utf8)))
        try FileManager.default.createSymbolicLink(atPath: log, withDestinationPath: target)
        try runBridge(debug: true)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "untouched\n")
    }

    func testNothingIsWrittenToAFileLinkedElsewhere() throws {
        let target = scratch + "/zshrc"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("untouched\n".utf8)))
        try FileManager.default.linkItem(atPath: target, toPath: log)
        try runBridge(debug: true)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "untouched\n")
    }

    func testAFIFOAtThePathDoesNotHangTheHook() throws {
        XCTAssertEqual(mkfifo(log, 0o600), 0)
        try runBridge(debug: true)
    }
}
