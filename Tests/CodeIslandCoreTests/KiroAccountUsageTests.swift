import XCTest
@testable import CodeIslandCore

final class KiroAccountUsageTests: XCTestCase {
    func testParsesCreditBreakdownAndResetDate() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "kiro.resourceNotifications.usageState": [
                "timestamp": 1_789_551_790_802,
                "usageBreakdowns": [[
                    "type": "CREDIT",
                    "currentUsage": 5316.10,
                    "usageLimit": 5000,
                    "percentageUsed": 106.322,
                    "currentOverages": 316.10,
                    "resetDate": "2026-10-01T00:00:00.000Z",
                ]],
            ],
        ])
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let snapshot = KiroAccountUsageParser.parse(data: data, fetchedAt: fetchedAt)
        XCTAssertNotNil(snapshot)
        guard let snapshot else { return }
        XCTAssertEqual(snapshot.currentUsage, 5316.10, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usageLimit, 5000, accuracy: 0.0001)
        XCTAssertEqual(snapshot.percentageUsed, 106.322, accuracy: 0.0001)
        XCTAssertEqual(snapshot.currentOverages, 316.10, accuracy: 0.0001)
        XCTAssertEqual(snapshot.resetAt, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertNotNil(snapshot.sourceUpdatedAt)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testSelectsCreditBreakdownWhenOtherResourcesComeFirst() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "kiro.resourceNotifications.usageState": [
                "usageBreakdowns": [
                    ["type": "INVOCATION", "currentUsage": 2, "usageLimit": 10, "resetDate": "2026-10-01T00:00:00Z"],
                    ["displayNamePlural": "Credits", "currentUsage": "12.5", "usageLimit": "20", "resetDate": "2026-10-01T00:00:00Z"],
                ],
            ],
        ])
        guard let snapshot = KiroAccountUsageParser.parse(data: data) else {
            return XCTFail("expected credit breakdown")
        }
        XCTAssertEqual(snapshot.currentUsage, 12.5, accuracy: 0.0001)
    }

    func testRejectsMissingOrInvalidAccountUsage() throws {
        let missing = try JSONSerialization.data(withJSONObject: [:])
        XCTAssertNil(KiroAccountUsageParser.parse(data: missing))
        let invalid = try JSONSerialization.data(withJSONObject: [
            "kiro.resourceNotifications.usageState": [
                "usageBreakdowns": [["currentUsage": 1, "usageLimit": 0, "resetDate": "bad"]],
            ],
        ])
        XCTAssertNil(KiroAccountUsageParser.parse(data: invalid))

        let unknownResource = try JSONSerialization.data(withJSONObject: [
            "kiro.resourceNotifications.usageState": [
                "usageBreakdowns": [["type": "INVOCATION", "currentUsage": 2, "usageLimit": 10, "resetDate": "2026-10-01T00:00:00Z"]],
            ],
        ])
        XCTAssertNil(KiroAccountUsageParser.parse(data: unknownResource))
    }
}
