import XCTest
@testable import CodeIslandCore

/// T3 Code (#321) runs the real agent CLIs as its own children. These pin which
/// ancestry shapes count as "under T3 Code" — and, just as important, which
/// look-alikes must not.
final class HostHarnessResolverTests: XCTestCase {
    private let home = "/Users/u"

    private func claude(_ pid: Int32 = 900) -> ProcessAncestor {
        ProcessAncestor(
            pid: pid,
            executablePath: "/Users/u/.local/share/claude/versions/2.1.120",
            arguments: ["claude", "--output-format", "stream-json", "--session-id=5b0c…"]
        )
    }

    private let zsh = ProcessAncestor(pid: 300, executablePath: "/bin/zsh", arguments: ["-zsh"])
    private let ghostty = ProcessAncestor(
        pid: 200,
        executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        bundleIdentifier: "com.mitchellh.ghostty"
    )

    // MARK: - Desktop app

    /// The Electron main process re-runs its own executable with
    /// ELECTRON_RUN_AS_NODE as the backend, so the agent's parent carries the
    /// app's bundle id even though it is not a GUI process.
    func testDesktopBackendIsRecognisedByBundleId() {
        let backend = ProcessAncestor(
            pid: 501,
            executablePath: "/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)",
            arguments: [
                "/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)",
                "/Applications/T3 Code (Alpha).app/Contents/Resources/app.asar/apps/server/dist/bin.mjs",
                "--bootstrap-fd", "3",
            ],
            bundleIdentifier: "com.t3tools.t3code"
        )
        let main = ProcessAncestor(
            pid: 500,
            executablePath: backend.executablePath,
            arguments: [backend.executablePath!],
            bundleIdentifier: "com.t3tools.t3code"
        )

        let harness = HostHarnessResolver.detect(ancestry: [claude(), backend, main], homeDirectory: home)

        XCTAssertEqual(harness?.kind, .t3Code)
        XCTAssertEqual(harness?.surface, .desktopApp(bundleId: "com.t3tools.t3code"))
        XCTAssertEqual(harness?.serverPid, 501, "the nearest T3 process owns the agent")
        XCTAssertEqual(harness?.label, "T3 Code")
        XCTAssertEqual(harness?.canJump, true, "desktop jump = bring the app forward, always possible")
    }

    /// Nightly/Alpha rename the product, never the app id — the match must not
    /// depend on the `.app` name.
    func testDesktopMatchIgnoresProductName() {
        let backend = ProcessAncestor(
            pid: 501,
            executablePath: "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)",
            bundleIdentifier: "com.t3tools.t3code"
        )
        XCTAssertNotNil(HostHarnessResolver.detect(ancestry: [claude(), backend], homeDirectory: home))

        let renamedLookalike = ProcessAncestor(
            pid: 501,
            executablePath: "/Applications/T3 Code.app/Contents/MacOS/T3 Code",
            bundleIdentifier: "com.example.not-t3"
        )
        XCTAssertNil(HostHarnessResolver.detect(ancestry: [claude(), renamedLookalike], homeDirectory: home))
    }

    // MARK: - Browser servers

    /// install.sh: `~/.local/bin/t3` symlinks into `~/.t3/runtime/versions/<v>/t3`;
    /// proc_pidpath reports the resolved path.
    func testInstalledSingleExecutableServer() {
        let server = ProcessAncestor(
            pid: 400,
            executablePath: "/Users/u/.t3/runtime/versions/0.0.42/t3",
            arguments: ["t3"]
        )
        let harness = HostHarnessResolver.detect(ancestry: [claude(), server, zsh, ghostty], homeDirectory: home)

        XCTAssertEqual(harness?.surface, .browser)
        XCTAssertEqual(harness?.serverPid, 400)
        XCTAssertEqual(harness?.stateDirectories, ["/Users/u/.t3/userdata", "/Users/u/.t3/dev"])
        XCTAssertNil(harness?.browserOrigin)
        XCTAssertEqual(harness?.canJump, false, "no verified URL yet → affordance hidden, not a guessed port")
    }

    /// `npx t3`: a CJS launcher under node spawns the platform binary, which is
    /// the actual server. The nearer process is the one to pin.
    func testNpxLauncherResolvesToThePlatformBinary() {
        let codex = ProcessAncestor(pid: 901, executablePath: "/opt/homebrew/bin/codex", arguments: ["codex", "app-server"])
        let server = ProcessAncestor(
            pid: 410,
            executablePath: "/Users/u/.npm/_npx/abc/node_modules/@t3code/t3-darwin-arm64/t3",
            arguments: ["/Users/u/.npm/_npx/abc/node_modules/@t3code/t3-darwin-arm64/t3"]
        )
        let launcher = ProcessAncestor(
            pid: 409,
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["node", "/Users/u/.npm/_npx/abc/node_modules/t3/bin/t3.js"]
        )

        let harness = HostHarnessResolver.detect(ancestry: [codex, server, launcher, zsh], homeDirectory: home)
        XCTAssertEqual(harness?.serverPid, 410)
    }

    /// launchd service: `t3 __service-launcher` supervises `t3 serve`.
    func testServiceLauncherPicksTheServeChild() {
        let serve = ProcessAncestor(pid: 420, executablePath: "/Users/u/.t3/runtime/versions/0.0.42/t3", arguments: ["t3", "serve"])
        let launcher = ProcessAncestor(pid: 419, executablePath: serve.executablePath, arguments: ["t3", "__service-launcher"])
        let harness = HostHarnessResolver.detect(ancestry: [claude(), serve, launcher], homeDirectory: home)
        XCTAssertEqual(harness?.serverPid, 420)
    }

    /// Releases before 0.0.41 ran the server as a script under node.
    func testLegacyNodeServerIsRecognisedFromArgv() {
        let server = ProcessAncestor(
            pid: 430,
            executablePath: "/opt/homebrew/Cellar/node/24.1.0/bin/node",
            arguments: ["node", "/opt/homebrew/lib/node_modules/t3/dist/bin.mjs"]
        )
        XCTAssertEqual(HostHarnessResolver.detect(ancestry: [claude(), server], homeDirectory: home)?.surface, .browser)
    }

    /// An agent typed into T3's integrated terminal (claude → zsh → t3) is
    /// still under T3 Code.
    func testShellInsideT3IntegratedTerminalStillCounts() {
        let server = ProcessAncestor(pid: 400, executablePath: "/Users/u/.t3/runtime/versions/0.0.42/t3")
        XCTAssertNotNil(HostHarnessResolver.detect(ancestry: [claude(), zsh, server], homeDirectory: home))
    }

    // MARK: - Look-alikes that must not match

    func testLookalikesAreNotT3() {
        let cases: [(String, ProcessAncestor)] = [
            ("a clone of the t3code repo running its own server build",
             ProcessAncestor(pid: 1, executablePath: "/opt/homebrew/bin/node",
                             arguments: ["node", "/Users/u/code/t3code/apps/server/dist/bin.mjs"])),
            ("an unrelated binary that happens to be called t3",
             ProcessAncestor(pid: 1, executablePath: "/usr/local/bin/t3", arguments: ["t3"])),
            ("another Electron app's backend with the same argv shape",
             ProcessAncestor(pid: 1, executablePath: "/Applications/Other.app/Contents/MacOS/Other",
                             arguments: ["Other", "/Applications/Other.app/Contents/Resources/app.asar/apps/server/dist/bin.mjs", "--bootstrap-fd", "3"],
                             bundleIdentifier: "com.other.app")),
            ("a directory merely named t3code",
             ProcessAncestor(pid: 1, executablePath: "/Users/u/t3code/bin/tool", arguments: ["tool", "--t3"])),
            ("a bundle id that only starts with the same letters",
             ProcessAncestor(pid: 1, executablePath: "/Applications/X.app/Contents/MacOS/X",
                             bundleIdentifier: "com.t3tools.t3codex")),
        ]
        for (label, ancestor) in cases {
            XCTAssertNil(
                HostHarnessResolver.detect(ancestry: [claude(), ancestor, zsh, ghostty], homeDirectory: home),
                label
            )
        }
    }

    func testPlainTerminalChainHasNoHarness() {
        XCTAssertNil(HostHarnessResolver.detect(ancestry: [claude(), zsh, ghostty], homeDirectory: home))
    }

    func testWalkIsBoundedByMaxDepth() {
        let filler = (0..<HostHarnessResolver.maxAncestryDepth).map {
            ProcessAncestor(pid: Int32(1000 + $0), executablePath: "/bin/sh")
        }
        let server = ProcessAncestor(pid: 400, executablePath: "/Users/u/.t3/runtime/versions/0.0.42/t3")
        XCTAssertNil(HostHarnessResolver.detect(ancestry: filler + [server], homeDirectory: home))
    }

    // MARK: - State directory

    func testStateDirectoryPrecedenceFollowsT3() {
        XCTAssertEqual(
            HostHarnessResolver.t3StateDirectories(
                arguments: ["t3", "serve", "--base-dir", "~/t3-data"],
                environment: ["T3CODE_HOME": "/env/home"],
                homeDirectory: home
            ).first,
            "/Users/u/t3-data/userdata",
            "--base-dir beats T3CODE_HOME"
        )
        XCTAssertEqual(
            HostHarnessResolver.t3StateDirectories(
                arguments: ["t3", "--base-dir=/data/t3"], environment: [:], homeDirectory: home
            ).first,
            "/data/t3/userdata"
        )
        XCTAssertEqual(
            HostHarnessResolver.t3StateDirectories(
                arguments: ["t3"], environment: ["T3CODE_HOME": "/env/home"], homeDirectory: home
            ).first,
            "/env/home/userdata"
        )
    }

    // MARK: - Browser origin

    private func runtime(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    func testOriginRequiresTheRuntimeFileOfThisServer() {
        let data = runtime(["version": 1, "pid": 400, "port": 3773, "origin": "http://127.0.0.1:3773", "startedAt": "x"])
        XCTAssertEqual(HostHarnessResolver.t3BrowserOrigin(runtimeJSON: data, expectedPid: 400), "http://localhost:3773")
        XCTAssertNil(
            HostHarnessResolver.t3BrowserOrigin(runtimeJSON: data, expectedPid: 401),
            "desktop and CLI share the default state dir; a file written by another server must be ignored"
        )
    }

    /// T3 pairs the browser at `localhost` for loopback/unset/wildcard binds,
    /// so that is where the auth cookie lives.
    func testOriginHostMatchesT3PairingHost() {
        for host in ["127.0.0.1", "localhost", "::1", "0.0.0.0", "::"] {
            let data = runtime(["pid": 1, "port": 4000, "host": host])
            XCTAssertEqual(HostHarnessResolver.t3BrowserOrigin(runtimeJSON: data, expectedPid: 1), "http://localhost:4000", host)
        }
        XCTAssertEqual(
            HostHarnessResolver.t3BrowserOrigin(runtimeJSON: runtime(["pid": 1, "port": 4000, "host": "100.64.0.7"]), expectedPid: 1),
            "http://100.64.0.7:4000"
        )
        XCTAssertEqual(
            HostHarnessResolver.t3BrowserOrigin(runtimeJSON: runtime(["pid": 1, "port": 4000, "host": "fd00::7"]), expectedPid: 1),
            "http://[fd00::7]:4000"
        )
    }

    func testOriginRejectsMalformedRuntimeFiles() {
        XCTAssertNil(HostHarnessResolver.t3BrowserOrigin(runtimeJSON: Data("not json".utf8), expectedPid: 1))
        XCTAssertNil(HostHarnessResolver.t3BrowserOrigin(runtimeJSON: runtime(["pid": 1]), expectedPid: 1))
        XCTAssertNil(HostHarnessResolver.t3BrowserOrigin(runtimeJSON: runtime(["pid": 1, "port": 0]), expectedPid: 1))
    }

    // MARK: - Thread URL

    func testThreadURLUsesT3ChatRoute() {
        let url = HostHarnessResolver.t3BrowserURL(
            origin: "http://localhost:3773",
            environmentId: "0f5f7c1e-8c1a-4f7b-9b1e-2b3c4d5e6f70",
            threadId: "7d2c9a4e-1b3f-4c5d-8e9f-0a1b2c3d4e5f"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "http://localhost:3773/0f5f7c1e-8c1a-4f7b-9b1e-2b3c4d5e6f70/7d2c9a4e-1b3f-4c5d-8e9f-0a1b2c3d4e5f"
        )
    }

    func testThreadURLFallsBackToRootWhenThreadIsUnknown() {
        XCTAssertEqual(
            HostHarnessResolver.t3BrowserURL(origin: "http://localhost:3773", environmentId: "env", threadId: nil)?.absoluteString,
            "http://localhost:3773/"
        )
        XCTAssertEqual(
            HostHarnessResolver.t3BrowserURL(origin: "http://localhost:3773", environmentId: nil, threadId: "t")?.absoluteString,
            "http://localhost:3773/"
        )
    }

    func testThreadURLRejectsNonTokenIds() {
        XCTAssertEqual(
            HostHarnessResolver.t3BrowserURL(origin: "http://localhost:3773", environmentId: "env", threadId: "../settings")?.absoluteString,
            "http://localhost:3773/"
        )
    }

    func testProviderSessionIdCandidates() {
        XCTAssertEqual(
            HostHarnessResolver.providerSessionIdCandidates(sessionId: "opencode-ses_abc", source: "opencode", providerSessionId: nil),
            ["ses_abc"],
            "the plugin prefixes OpenCode ids; T3 stores the raw one"
        )
        XCTAssertEqual(
            HostHarnessResolver.providerSessionIdCandidates(sessionId: "uuid-1", source: "claude", providerSessionId: "uuid-1"),
            ["uuid-1"]
        )
    }

    func testOutermostAppBundleIsTheAppNotAHelper() {
        XCTAssertEqual(
            HostHarnessResolver.outermostAppBundlePath(
                forExecutable: "/Applications/T3 Code (Alpha).app/Contents/Frameworks/T3 Code (Alpha) Helper.app/Contents/MacOS/T3 Code (Alpha) Helper"
            ),
            "/Applications/T3 Code (Alpha).app"
        )
        XCTAssertNil(HostHarnessResolver.outermostAppBundlePath(forExecutable: "/usr/bin/node"))
    }

    // MARK: - KERN_PROCARGS2

    func testProcArgsParserReadsArgvAndRequestedEnvironment() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3).littleEndian) { buffer.append(contentsOf: $0) }
        func cString(_ s: String) { buffer.append(contentsOf: Array(s.utf8)); buffer.append(0) }
        cString("/Users/u/.t3/runtime/versions/0.0.42/t3")
        buffer.append(contentsOf: [0, 0, 0])                // exec-path padding
        cString("t3"); cString("serve"); cString("--base-dir=/d")
        cString("PATH=/usr/bin"); cString("T3CODE_HOME=/h"); cString("")

        let parsed = ProcArgsParser.parse(buffer, environmentKeys: ["T3CODE_HOME"])
        XCTAssertEqual(parsed?.arguments, ["t3", "serve", "--base-dir=/d"])
        XCTAssertEqual(parsed?.environment, ["T3CODE_HOME": "/h"], "only requested keys are kept")
        XCTAssertNil(ProcArgsParser.parse([1, 0]))
    }

    // MARK: - Snapshot surface

    func testHostedSessionBadgeAndJumpRules() {
        var snapshot = SessionSnapshot()
        snapshot.termBundleId = "com.googlecode.iterm2"
        snapshot.tmuxEnv = "/private/tmp/tmux-501/default,1,0"
        XCTAssertEqual(snapshot.multiplexerLabel, "tmux")
        XCTAssertTrue(snapshot.canJumpFromNotch)

        snapshot.hostHarness = HostHarness(kind: .t3Code, surface: .browser, serverPid: 400)
        XCTAssertEqual(snapshot.hostHarnessLabel, "T3 Code")
        XCTAssertNil(snapshot.multiplexerLabel, "tmux was inherited by the T3 server, the conversation is not in that pane")
        XCTAssertEqual(snapshot.terminalName, "iTerm2", "the chip augments the terminal name, never replaces it")
        XCTAssertFalse(snapshot.canJumpFromNotch, "unverified harness URL hides the jump")

        snapshot.hostHarness?.browserOrigin = "http://localhost:3773"
        XCTAssertTrue(snapshot.canJumpFromNotch)

        snapshot.remoteHostId = "box"
        XCTAssertFalse(snapshot.canJumpFromNotch, "remote still wins")
    }
}
