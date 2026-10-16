import XCTest
@testable import CodeIslandCore

final class CmuxTerminalResolverTests: XCTestCase {
    private func candidate(
        pid: Int32, cwd: String = "/repo", surface: String,
        workspace: String, hasTTY: Bool = true
    ) -> CmuxTerminalResolver.Candidate {
        .init(pid: pid, cwd: cwd, hasTTY: hasTTY,
              surfaceId: surface, workspaceId: workspace)
    }

    func testSharedDaemonEnvironmentDoesNotOverrideLiveTerminal() {
        let target = CmuxTerminalResolver.resolve(cwd: "/repo", candidates: [
            candidate(pid: 1, surface: "stale", workspace: "second", hasTTY: false),
            candidate(pid: 2, surface: "current", workspace: "first"),
        ], preferredSurfaceId: "stale")

        XCTAssertEqual(target?.surfaceId, "current")
        XCTAssertEqual(target?.workspaceId, "first")
    }

    func testOtherWorkingDirectoriesCannotOwnTheSession() {
        let target = CmuxTerminalResolver.resolve(cwd: "/repo", candidates: [
            candidate(pid: 2, cwd: "/other", surface: "other", workspace: "second"),
        ])
        XCTAssertNil(target)
    }

    func testAmbiguousTerminalsDoNotPickTheFirstProcess() {
        let targets = [
            candidate(pid: 2, surface: "one", workspace: "first"),
            candidate(pid: 3, surface: "two", workspace: "second"),
        ]
        XCTAssertNil(CmuxTerminalResolver.resolve(cwd: "/repo", candidates: targets))
        XCTAssertEqual(CmuxTerminalResolver.resolve(
            cwd: "/repo", candidates: targets, preferredSurfaceId: "two"
        )?.surfaceId, "two")
    }

    func testMissingWorkspaceAndDetachedDaemonsAreNotTargets() {
        XCTAssertNil(CmuxTerminalResolver.resolve(cwd: "/repo", candidates: [
            candidate(pid: 1, surface: "daemon", workspace: "old", hasTTY: false),
            candidate(pid: 2, surface: "incomplete", workspace: ""),
        ]))
    }

    func testProcessArgumentsAreSkippedBeforeReadingCmuxEnvironment() {
        var argc: Int32 = 3
        var buffer = withUnsafeBytes(of: &argc) { Array($0) }
        buffer += Array("/bin/codex\0\0codex\0--config\0CMUX_SURFACE_ID=argument\0".utf8)
        buffer += Array("UNRELATED=value\0CMUX_SURFACE_ID= current \0CMUX_WORKSPACE_ID=first\0\0".utf8)

        XCTAssertEqual(CmuxTerminalResolver.cmuxEnvironment(processArguments: buffer), [
            "CMUX_SURFACE_ID": "current", "CMUX_WORKSPACE_ID": "first",
        ])
    }

    func testTruncatedProcessArgumentsCannotBecomeTerminalMetadata() {
        XCTAssertNil(CmuxTerminalResolver.cmuxEnvironment(processArguments: [0, 0, 0]))
        var argc: Int32 = 2
        let buffer = withUnsafeBytes(of: &argc) { Array($0) } + Array("/bin/codex\0codex".utf8)
        XCTAssertNil(CmuxTerminalResolver.cmuxEnvironment(processArguments: buffer))
    }
}
