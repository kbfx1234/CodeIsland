import XCTest
@testable import CodeIsland

/// The project name on a card opens the session's cwd, a path from the hook.
/// Handed to NSWorkspace as is, an app bundle or a script there would be
/// launched instead of shown.
final class HookFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAFolderOpens() throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        XCTAssertEqual(HookFolder.openableURL(project.path)?.path, project.path)
    }

    func testAnythingThatWouldLaunchIsNotOpened() throws {
        let app = root.appendingPathComponent("Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        let script = root.appendingPathComponent("run.command")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        let linkToApp = root.appendingPathComponent("project-link")
        try FileManager.default.createSymbolicLink(at: linkToApp, withDestinationURL: app)

        XCTAssertNil(HookFolder.openableURL(app.path), "an app bundle")
        XCTAssertNil(HookFolder.openableURL(script.path), "a file")
        XCTAssertNil(HookFolder.openableURL(linkToApp.path), "a link to an app bundle")
        XCTAssertNil(HookFolder.openableURL(root.appendingPathComponent("gone").path), "nothing there")
        XCTAssertNil(HookFolder.openableURL("project"), "relative")
    }
}
