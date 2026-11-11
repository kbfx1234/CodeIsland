import XCTest
@testable import CodeIsland
import CodeIslandCore

final class TerminalActivatorCodexDeepLinkTests: XCTestCase {
    func testBuildsCodexDesktopThreadURLFromRawIdentifier() {
        let url = TerminalActivator.codexDesktopThreadURL(
            providerSessionId: "01a06745-0c2d-70c1-92c2-d2f63bf02ecc"
        )

        XCTAssertEqual(
            url?.absoluteString,
            "codex://threads/01a06745-0c2d-70c1-92c2-d2f63bf02ecc"
        )
    }

    func testBuildsURLFromLegacyCodexAppPrefix() {
        let url = TerminalActivator.codexDesktopThreadURL(
            providerSessionId: "codexapp:desktop-thread"
        )

        XCTAssertEqual(url?.absoluteString, "codex://threads/desktop-thread")
    }

    func testTrimsWhitespace() {
        let url = TerminalActivator.codexDesktopThreadURL(providerSessionId: "  thread-1 \n")

        XCTAssertEqual(url?.absoluteString, "codex://threads/thread-1")
    }

    func testRejectsMissingOrEmptyIdentifier() {
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(providerSessionId: nil))
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(providerSessionId: ""))
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(providerSessionId: "codexapp:"))
    }

    func testRejectsPathSeparatorsAndQueryCharacters() {
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(providerSessionId: "thread/other"))
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(providerSessionId: "thread?other"))
        XCTAssertNil(TerminalActivator.codexDesktopThreadURL(providerSessionId: "thread#other"))
    }

    func testCmuxSurfaceIsAuthoritative() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.openai.codex"
        session.cmuxSurfaceId = " surface-1 "

        XCTAssertTrue(TerminalActivator.isCmuxSession(session))
    }

    func testCmuxBundleIsRecognizedWithoutSurface() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.cmuxterm.app"

        XCTAssertTrue(TerminalActivator.isCmuxSession(session))
    }

    func testNonCmuxCodexDesktopIsNotCmux() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.openai.codex"

        XCTAssertFalse(TerminalActivator.isCmuxSession(session))
    }

    func testCmuxFocusArgumentsIncludeSurfaceAndWorkspace() {
        XCTAssertEqual(
            TerminalActivator.cmuxFocusArguments(
                surfaceId: " surface-1 ",
                workspaceId: " workspace-2 "
            ),
            ["focus-panel", "--panel", "surface-1", "--workspace", "workspace-2"]
        )
    }

    func testCmuxFocusArgumentsOmitMissingWorkspace() {
        XCTAssertEqual(
            TerminalActivator.cmuxFocusArguments(surfaceId: "surface-1", workspaceId: "  "),
            ["focus-panel", "--panel", "surface-1"]
        )
    }

    func testCmuxFocusArgumentsRejectMissingSurface() {
        XCTAssertNil(TerminalActivator.cmuxFocusArguments(surfaceId: nil, workspaceId: "workspace-1"))
        XCTAssertNil(TerminalActivator.cmuxFocusArguments(surfaceId: " \n", workspaceId: nil))
    }
}
