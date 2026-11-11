import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// #341 — Trae CN is its own install: `/Applications/Trae CN.app`, bundle id
/// `cn.trae.app`, main binary `Electron`, helpers `Trae CN Helper …` (Homebrew
/// `trae-cn` cask; TraeCode CN 3.3.104 Info.plist). CodeIsland assumed it
/// lived at `TraeCN.app` or inside the international `Trae.app` under
/// `com.trae.app`, so it was never recognised as itself.
final class TraeCNIDEBundleTests: XCTestCase {
    private let mainBinary = "/Applications/Trae CN.app/Contents/MacOS/Electron"
    private let pluginHelper = "/Applications/Trae CN.app/Contents/Frameworks/Trae CN Helper (Plugin).app/Contents/MacOS/Trae CN Helper (Plugin)"
    private let internationalTrae = "/Applications/Trae.app/Contents/MacOS/Electron"

    func testRecognisesTheShippedBundleName() {
        XCTAssertTrue(AgentProcessFinder.isTraeCNIDEBundlePath(mainBinary))
        XCTAssertTrue(AgentProcessFinder.isTraeCNIDEBundlePath(pluginHelper))
    }

    /// The product's `nameAlias` is now "TraeCode CN"; a bundle rename to it
    /// must keep working, as must the name this code first assumed.
    func testRecognisesTheAlternativeBundleNames() {
        XCTAssertTrue(AgentProcessFinder.isTraeCNIDEBundlePath(
            "/Applications/TraeCode CN.app/Contents/MacOS/Electron"))
        XCTAssertTrue(AgentProcessFinder.isTraeCNIDEBundlePath(
            "/Applications/TraeCN.app/Contents/MacOS/Electron"))
    }

    /// Before #341 `traecn` also matched `/trae.app/`, so an open international
    /// Trae kept Trae CN sessions alive (and vice versa for jump targets).
    func testDoesNotMatchInternationalTrae() {
        XCTAssertFalse(AgentProcessFinder.isTraeCNIDEBundlePath(internationalTrae))
        XCTAssertFalse(AgentProcessFinder.isTraeCNIDEBundlePath(
            "/Applications/Trae.app/Contents/Frameworks/Trae Helper (Plugin).app/Contents/MacOS/Trae Helper (Plugin)"))
    }

    /// Hooks run through `bash -c`; the bridge must track the long-lived
    /// Trae CN process, not the shell that exits as soon as the hook returns.
    func testBridgeTracksTheTraeCNProcessInsteadOfTheHookShell() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (pid: 100, executablePath: "/bin/bash"),
            (pid: 200, executablePath: pluginHelper),
            (pid: 300, executablePath: mainBinary),
        ]
        XCTAssertEqual(
            CLIProcessResolver.resolvedTrackedPID(immediateParentPID: 100, source: "traecn", ancestry: ancestry),
            200
        )
        XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath(internationalTrae, source: "traecn"))
        XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath("/bin/bash", source: "traecn"))
    }

    /// Trae CN stays a desktop-IDE host: a CLI started in its integrated
    /// terminal must not be re-branded as Trae CN by ancestry inference (#220).
    func testAncestryInferenceStillSkipsTheTraeCNHost() {
        XCTAssertNil(CLIProcessResolver.inferSource(ancestry: [(pid: 200, executablePath: pluginHelper)]))
    }

    func testBundleIdMapsToTraeCN() {
        XCTAssertEqual(SessionSnapshot.sourceForAppBundleId("cn.trae.app"), "traecn")
        XCTAssertEqual(SessionSnapshot.sourceForAppBundleId("com.trae.app"), "trae")
        XCTAssertEqual(TerminalActivator.sourceToNativeAppBundleId["traecn"], "cn.trae.app")
        XCTAssertEqual(TerminalActivator.sourceToNativeAppBundleId["trae"], "com.trae.app")

        var agentSession = SessionSnapshot()
        agentSession.source = "traecn"
        agentSession.termBundleId = "cn.trae.app"
        XCTAssertTrue(agentSession.isNativeAppMode)
        XCTAssertEqual(agentSession.terminalName, "Trae CN")

        // Claude Code run in Trae CN's integrated terminal is an IDE terminal
        // session, not a Trae CN agent session.
        var terminalSession = SessionSnapshot()
        terminalSession.source = "claude"
        terminalSession.termBundleId = "cn.trae.app"
        XCTAssertFalse(terminalSession.isNativeAppMode)
        XCTAssertTrue(terminalSession.isIDETerminal)
    }
}
