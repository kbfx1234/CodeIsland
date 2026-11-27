import XCTest
@testable import CodeIsland

final class RexRoutingTests: XCTestCase {
    func testRexIsRecognizedAsAWindowedTerminal() {
        XCTAssertTrue(TerminalActivator.knownTerminals.contains {
            $0.bundleId == "com.superlogical.rex"
        })
    }

    func testRexBinaryPathPrefersTheInheritedServerDirectory() {
        let path = TerminalActivator.rexBinaryPath(
            environment: ["REX_BIN_DIR": "/custom/rex/bin"],
            fileExists: { $0 == "/custom/rex/bin/rex" }
        )
        XCTAssertEqual(path, "/custom/rex/bin/rex")
    }
}
