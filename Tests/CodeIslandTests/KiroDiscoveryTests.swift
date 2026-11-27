import XCTest
@testable import CodeIsland

final class KiroDiscoveryTests: XCTestCase {
    func testDiscoveryRequiresAnActiveRecordFromTheLiveLeaseOwner() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "sess_00000000-0000-4000-8000-000000000001"
        let sessionDir = home.appendingPathComponent("sessions/workspace/\(id)")
        let leasesDir = home.appendingPathComponent("session-leases")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leasesDir, withIntermediateDirectories: true)
        let lease = #"{"pid":123,"clientName":"kiro-cli","acquiredAt":"2026-11-27T02:00:00.250Z"}"#
        try Data(lease.utf8).write(to: leasesDir.appendingPathComponent(id + ".lease"))
        let recordURL = sessionDir.appendingPathComponent("session.json")
        func writeRecord(status: String) throws {
            let record = """
                {"id":"\(id)","status":"\(status)","rootPaths":["/tmp/project"],
                "lastModifiedAt":"2026-11-27T02:15:00.000Z","modelId":"example"}
                """
            try Data(record.utf8).write(to: recordURL)
        }
        let startedAt = try XCTUnwrap(SessionDiscovery.parseISO8601Timestamp("2026-11-27T02:00:00Z"))
        let owner = ProcessIdentity(pid: 123, startTime: startedAt)

        try writeRecord(status: "in_progress")
        let found = KiroDiscovery.activeSessions(home: home, kiroProcess: { _ in owner })
        XCTAssertEqual(found.map(\.sessionId), [id])
        XCTAssertEqual(found.first?.status, .processing)
        XCTAssertEqual(found.first?.pid, 123)
        XCTAssertEqual(found.first?.cwd, "/tmp/project")
        XCTAssertTrue(KiroDiscovery.activeSessions(home: home, kiroProcess: { _ in nil }).isEmpty)

        let reused = ProcessIdentity(pid: 123, startTime: startedAt.addingTimeInterval(60))
        XCTAssertTrue(KiroDiscovery.activeSessions(home: home, kiroProcess: { _ in reused }).isEmpty)

        try writeRecord(status: "idle")
        XCTAssertTrue(KiroDiscovery.activeSessions(sessionId: id, home: home, kiroProcess: { _ in owner }).isEmpty)
    }
}
