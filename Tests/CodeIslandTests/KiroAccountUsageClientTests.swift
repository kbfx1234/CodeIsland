import XCTest
@testable import CodeIsland

final class KiroAccountUsageClientTests: XCTestCase {
    func testReadsCreditsAfterInitializingACP() throws {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("kiro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cli) }
        let script = #"""
        #!/bin/sh
        test "$*" = "acp --agent-engine=v3 --auth-method=cli" || exit 1
        IFS= read -r request || exit 1
        test "$(printf '%s' "$request" | /usr/bin/plutil -extract method raw -o - -)" = initialize || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2}}'
        IFS= read -r request || exit 1
        test "$(printf '%s' "$request" | /usr/bin/plutil -extract method raw -o - -)" = _kiro/account/getUsage || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"success":true,"data":{"billingCycleReset":"2026-12-01","usageBreakdowns":[{"displayName":"Credits","used":0,"limit":1}]}}}'
        IFS= read -r request
        """#
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let snapshot = try XCTUnwrap(KiroAccountUsageClient.fetch(executable: cli, timeout: 2))
        XCTAssertEqual(snapshot.currentUsage, 0)
        XCTAssertEqual(snapshot.usageLimit, 1)
        XCTAssertEqual(snapshot.resetAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testReturnsNilWhenCLIExitsBeforeHandshake() {
        let cli = URL(fileURLWithPath: "/usr/bin/false")
        XCTAssertNil(KiroAccountUsageClient.fetch(executable: cli, timeout: 2))
    }
}
