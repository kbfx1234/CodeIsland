import XCTest
@testable import CodeIsland

final class HerdrDesktopControllerTests: XCTestCase {
    func testFocusUsesHerdrAppPaneCommand() throws {
        let executable = try temporaryExecutable()
        var invocation: (String, [String], TimeInterval)?

        XCTAssertTrue(HerdrDesktopController.focus(
            terminalId: "t3",
            executablePath: executable.path
        ) { path, args, timeout in
            invocation = (path, args, timeout)
            return Data(#"{"ok":true}"#.utf8)
        })

        XCTAssertEqual(invocation?.0, executable.path)
        XCTAssertEqual(invocation?.1, ["do", "pane.focus", #"{"terminal":"t3"}"#])
        XCTAssertEqual(invocation?.2, 2)
    }

    func testIsFocusedReadsFocusedAgentTerminal() throws {
        let executable = try temporaryExecutable()
        XCTAssertTrue(HerdrDesktopController.isFocused(
            terminalId: "t3",
            executablePath: executable.path
        ) { _, _, _ in
            Data(#"{"agent":"t3"}"#.utf8)
        })
    }

    private func temporaryExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
