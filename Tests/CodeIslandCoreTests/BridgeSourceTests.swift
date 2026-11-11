import XCTest
@testable import CodeIslandCore

/// `codeisland-bridge` stamps every event with a source and marks hooks that
/// reached it through another agent `_via_plugin` (#123). Direct plugins
/// (OpenCode, MiMo Code, Pi / OMP, OpenClaw) pipe their own blocking requests
/// in without `--source` but with `_source` set: that is declared, not
/// proxied — Agent Sub-Sessions' "hide" mode answers `_via_plugin` permission
/// requests with an automatic allow.
final class BridgeSourceTests: XCTestCase {
    private let underMimo: [(pid: Int32, executablePath: String?)] = [
        (800, "/Users/u/.mimocode/bin/mimo"),
        (700, "/bin/zsh"),
    ]
    private let underOpenCode: [(pid: Int32, executablePath: String?)] = [
        (800, "/Users/u/.opencode/bin/opencode"),
    ]

    func testPluginsOwnRequestIsDeclaredNotProxied() {
        for (payload, ancestry) in [("mimo", underMimo), ("opencode", underOpenCode), ("pi", underMimo)] {
            let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: payload, ancestry: ancestry)
            XCTAssertEqual(resolved.source, payload)
            XCTAssertFalse(resolved.viaPlugin, payload)
        }
    }

    func testAncestryDoesNotRelabelADeclaredPayloadSource() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: "opencode", ancestry: underMimo)
        XCTAssertEqual(resolved.source, "opencode")
    }

    func testPayloadAliasesNormalise() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: "MiMo Code", ancestry: [])
        XCTAssertEqual(resolved.source, "mimo")
        XCTAssertFalse(resolved.viaPlugin)
    }

    /// #95 / #123 unchanged: a Claude-format hook with no source anywhere is
    /// attributed by ancestry and marked as proxied.
    func testSourcelessHookIsInferredAndMarked() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: nil, ancestry: underOpenCode)
        XCTAssertEqual(resolved.source, "opencode")
        XCTAssertTrue(resolved.viaPlugin)
    }

    /// Claude Code's own hook (the source-less `codeisland-hook.sh`) under a
    /// Claude binary is not a proxy, or "hide" would auto-allow its approvals
    /// and drop the session. Another agent firing that hook still is (#95).
    func testClaudesOwnHookIsNotProxied() {
        for claude in [
            "/opt/homebrew/Caskroom/claude-code/2.1.0/claude",
            "/Applications/Claude.app/Contents/MacOS/Claude",
        ] {
            let resolved = CLIProcessResolver.bridgeSource(
                sourceTag: nil, payloadSource: nil, ancestry: [(900, "/bin/sh"), (800, claude)]
            )
            XCTAssertEqual(resolved.source, "claude", claude)
            XCTAssertFalse(resolved.viaPlugin, claude)
        }
        let omoUnderClaude = CLIProcessResolver.bridgeSource(
            sourceTag: nil, payloadSource: nil,
            ancestry: underOpenCode + [(700, "/bin/zsh"), (600, "/opt/homebrew/Caskroom/claude-code/2.1.0/claude")]
        )
        XCTAssertEqual(omoUnderClaude.source, "opencode")
        XCTAssertTrue(omoUnderClaude.viaPlugin)
    }

    /// Claude Code's native installer (its default) runs the binary as
    /// `~/.local/share/claude/versions/<version>`. That is Claude firing its
    /// own hook too: the walk must stop there instead of going on to whatever
    /// hosts it — an editor or desktop app with a terminal (Kiro, ZCode, the
    /// Codex app), Codex or OpenCode running `claude` as a tool, or a home
    /// folder whose name the loose `/<source>` rule claims (`/Users/pi…`).
    /// Attributed to the host and marked proxied, the session was relabelled,
    /// folded into the host's card by "merge", and hidden with its approvals
    /// auto-allowed by "hide".
    func testNativeClaudeInstallIsClaudesOwnHook() {
        let hosts = [
            "/Applications/Kiro.app/Contents/Frameworks/Kiro Helper (Plugin).app/Contents/MacOS/Kiro Helper (Plugin)",
            "/Applications/ZCode.app/Contents/MacOS/ZCode",
            "/Applications/Codex.app/Contents/MacOS/Codex",
            "/Users/u/.opencode/bin/opencode",
        ]
        for host in hosts {
            let resolved = CLIProcessResolver.bridgeSource(
                sourceTag: nil, payloadSource: nil,
                ancestry: [(900, "/Users/u/.local/share/claude/versions/2.1.294"), (800, "/bin/zsh"), (700, host)]
            )
            XCTAssertEqual(resolved.source, "claude", host)
            XCTAssertFalse(resolved.viaPlugin, host)
        }

        let homeNamedLikeASource = CLIProcessResolver.bridgeSource(
            sourceTag: nil, payloadSource: nil,
            ancestry: [(900, "/Users/pierre/.local/share/claude/versions/2.1.294"), (800, "/bin/zsh")]
        )
        XCTAssertEqual(homeNamedLikeASource.source, "claude")
        XCTAssertFalse(homeNamedLikeASource.viaPlugin)

        // Its `_ppid` is the Claude process, not a shell between it and the bridge.
        XCTAssertEqual(
            CLIProcessResolver.resolvedTrackedPID(
                immediateParentPID: 950,
                source: "claude",
                ancestry: [(950, "/bin/sh"), (900, "/Users/u/.local/share/claude/versions/2.1.294")]
            ),
            900
        )
    }

    /// An unknown payload source is no declaration: fall back to ancestry.
    func testUnknownPayloadSourceFallsBackToAncestry() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: "nonsense", ancestry: underMimo)
        XCTAssertEqual(resolved.source, "mimo")
        XCTAssertTrue(resolved.viaPlugin)
    }

    func testSourceFlagStillWinsAndStillPromotesCLIVariants() {
        let cursorAgent: [(pid: Int32, executablePath: String?)] = [
            (900, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: "cursor", payloadSource: "opencode", ancestry: cursorAgent)
        XCTAssertEqual(resolved.source, "cursor-cli")
        XCTAssertFalse(resolved.viaPlugin)

        let nothing = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: nil, ancestry: [(1, "/bin/zsh")])
        XCTAssertNil(nothing.source)
        XCTAssertFalse(nothing.viaPlugin)
    }

    // MARK: - Cursor running Claude Code's hooks (#377)

    /// The hook as reported: Cursor's extension host runs it, straight under
    /// Cursor.app — no Claude binary anywhere.
    private let underCursorExtensionHost: [(pid: Int32, executablePath: String?)] = [
        (900, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
        (800, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
    ]

    /// Cursor runs the Claude Code hooks in ~/.claude/settings.json, where
    /// CodeIsland's hook has no `--source`. Its payload says Cursor, and that
    /// is a declaration: marked as a proxy, "hide" would auto-allow and drop
    /// it like a plugin's.
    func testCursorRunningClaudeCodesHookIsCursor() {
        let resolved = CLIProcessResolver.bridgeSource(
            sourceTag: nil, payloadSource: nil, cursorPayload: true, ancestry: underCursorExtensionHost
        )
        XCTAssertEqual(resolved.source, "cursor")
        XCTAssertFalse(resolved.viaPlugin)
        // Same `_ppid` as the `--source cursor` hooks: the extension host.
        XCTAssertEqual(
            CLIProcessResolver.resolvedTrackedPID(
                immediateParentPID: 950,
                source: resolved.source,
                ancestry: [(950, "/bin/sh")] + underCursorExtensionHost
            ),
            900
        )
    }

    /// cursor-agent imports the same hooks; it is the CLI, as with `--source cursor`.
    func testCursorAgentRunningClaudeCodesHookIsCursorCLI() {
        let underCursorAgent: [(pid: Int32, executablePath: String?)] = [
            (950, "/bin/zsh"),
            (900, "/Users/u/.local/share/cursor-agent/versions/2026.09.26-dd393fe/cursor-agent"),
            (800, "/bin/zsh"),
        ]
        let resolved = CLIProcessResolver.bridgeSource(
            sourceTag: nil, payloadSource: nil, cursorPayload: true, ancestry: underCursorAgent
        )
        XCTAssertEqual(resolved.source, "cursor-cli")
        XCTAssertFalse(resolved.viaPlugin)
    }

    /// Only Cursor's payload says Cursor. Claude Code inside Cursor — its
    /// integrated terminal, or the Claude Code extension — sends Claude's own
    /// payload and stays Claude.
    func testClaudeCodeInsideCursorStaysClaude() {
        let terminal: [(pid: Int32, executablePath: String?)] = [
            (950, "/bin/sh"),
            (900, "/Users/u/.local/share/claude/versions/2.1.294"),
            (850, "/bin/zsh"),
            (800, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"),
            (700, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ]
        let extensionBinary: [(pid: Int32, executablePath: String?)] = [
            (950, "/bin/sh"),
            (900, "/Users/u/.cursor/extensions/anthropic.claude-code-2.1.294-darwin-arm64/resources/native-binary/claude"),
        ] + underCursorExtensionHost
        for ancestry in [terminal, extensionBinary] {
            let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: nil, ancestry: ancestry)
            XCTAssertEqual(resolved.source, "claude")
            XCTAssertFalse(resolved.viaPlugin)
        }
    }

    /// No ancestry rule stands in for the payload: Claude Code installed with
    /// npm runs as `node`, so in Cursor's terminal its hook has Cursor's
    /// processes above it and no Claude binary — the same shape as a hook
    /// Cursor runs itself (#220).
    func testCursorProcessesAloneNeverSayCursor() {
        let npmClaudeInCursorTerminal: [(pid: Int32, executablePath: String?)] = [
            (950, "/bin/sh"),
            (900, "/opt/homebrew/Cellar/node/24.1.0/bin/node"),
            (850, "/bin/zsh"),
            (800, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"),
            (700, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ]
        for ancestry in [npmClaudeInCursorTerminal, underCursorExtensionHost] {
            let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: nil, ancestry: ancestry)
            XCTAssertNil(resolved.source, "left to the app's default rather than guessed")
            XCTAssertFalse(resolved.viaPlugin)
        }
    }

    /// An explicit `--source` or plugin `_source` still outranks the payload.
    func testDeclaredSourceOutranksCursorsPayload() {
        XCTAssertEqual(
            CLIProcessResolver.bridgeSource(
                sourceTag: "traecli", payloadSource: nil, cursorPayload: true, ancestry: underCursorExtensionHost
            ).source,
            "traecli"
        )
        XCTAssertEqual(
            CLIProcessResolver.bridgeSource(
                sourceTag: nil, payloadSource: "opencode", cursorPayload: true, ancestry: underCursorExtensionHost
            ).source,
            "opencode"
        )
    }
}
