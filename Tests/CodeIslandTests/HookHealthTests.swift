import XCTest
@testable import CodeIsland

final class HookHealthTests: XCTestCase {
    func testOverallSeverityPrefersManualThenRepair() {
        let date = Date(timeIntervalSince1970: 0)
        let manual = HookHealthItem(id: "m", title: "manual", detail: "", severity: .manual)
        let repair = HookHealthItem(id: "r", title: "repair", detail: "", severity: .needsRepair)
        XCTAssertEqual(HookHealthReport(generatedAt: date, items: [repair, manual]).overallSeverity, .manual)
        XCTAssertEqual(HookHealthReport(generatedAt: date, items: [repair]).overallSeverity, .needsRepair)
        XCTAssertTrue(HookHealthReport(generatedAt: date, items: []).isHealthy)
    }

    func testHealthReportContainsSharedRuntimeChecks() {
        let report = ConfigInstaller.hookHealthReport(socketPath: "/path-that-does-not-exist")
        let ids = Set(report.items.map(\.id))
        XCTAssertTrue(ids.contains("bridge"))
        XCTAssertTrue(ids.contains("hook-script"))
        XCTAssertTrue(ids.contains("socket"))
        XCTAssertEqual(report.items.first(where: { $0.id == "socket" })?.severity, .needsRepair)
    }
}
