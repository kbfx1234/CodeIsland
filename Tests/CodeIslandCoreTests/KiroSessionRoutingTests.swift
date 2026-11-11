import XCTest
@testable import CodeIslandCore

final class KiroSessionRoutingTests: XCTestCase {
    func testRecognizesOnlyTheACPSubcommand() {
        XCTAssertTrue(KiroSessionRouting.isACPProcess(arguments: ["kiro-cli", "acp", "--agent-engine", "v2"]))
        XCTAssertTrue(KiroSessionRouting.isACPProcess(arguments: ["kiro-cli-chat", "acp"]))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(arguments: ["kiro-cli", "chat", "--v3"]))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(arguments: ["kiro-cli", "acp-helper"]))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(arguments: ["kiro-cli", "chat", "--prompt", "acp"]))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(arguments: ["claude", "acp"]))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(arguments: []))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(arguments: ["kiro-cli"]))
    }

    func testOnlyKiroACPHooksAreSuppressed() {
        XCTAssertFalse(KiroSessionRouting.shouldForwardHook(source: "kiro", isACPProcess: true))
        XCTAssertFalse(KiroSessionRouting.shouldForwardHook(source: "kiro-cli", isACPProcess: true))
        XCTAssertTrue(KiroSessionRouting.shouldForwardHook(source: "kiro", isACPProcess: false))
        XCTAssertTrue(KiroSessionRouting.shouldForwardHook(source: "claude", isACPProcess: true))
        XCTAssertTrue(KiroSessionRouting.shouldForwardHook(source: nil, isACPProcess: true))
    }

    func testUnknownAndUnrelatedProcessesAreKept() {
        XCTAssertFalse(KiroSessionRouting.isACPProcess(pid: 0))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(pid: -1))
        XCTAssertFalse(KiroSessionRouting.isACPProcess(pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(KiroSessionRouting.pid(from: NSNumber(value: 1234)), 1234)
        XCTAssertEqual(KiroSessionRouting.pid(from: 1234), 1234)
        XCTAssertNil(KiroSessionRouting.pid(from: "1234"))
    }

    func testSessionFilesMustBelongToTheirLockOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionId = UUID().uuidString
        let lock = directory.appendingPathComponent(sessionId + ".lock")
        try Data(#"{"pid":1234}"#.utf8).write(to: lock)
        XCTAssertEqual(KiroSessionRouting.ownerPID(sessionId: sessionId, in: directory), 1234)
        XCTAssertNil(KiroSessionRouting.ownerPID(sessionId: "../outside", in: directory))
        try Data(#"{"pid":0}"#.utf8).write(to: lock)
        XCTAssertNil(KiroSessionRouting.ownerPID(sessionId: sessionId, in: directory))
        try Data("incomplete".utf8).write(to: lock)
        XCTAssertNil(KiroSessionRouting.ownerPID(sessionId: sessionId, in: directory))
    }
}
