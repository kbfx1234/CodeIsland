import XCTest
@testable import CodeIslandCore

/// Path identity and symlink-preserving writes, on a real (temporary)
/// filesystem — symlinks and letter case are exactly what a fake probe would
/// get wrong.
final class ConfigPathIdentityTests: XCTestCase {
    private var base: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "config-path-identity-" + UUID().uuidString
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        ExtraConfigDirs.invalidateRootsCache()
    }

    override func tearDown() {
        try? fm.removeItem(atPath: base)
        ExtraConfigDirs.invalidateRootsCache()
        super.tearDown()
    }

    private func mkdir(_ relative: String) throws -> String {
        let path = base + "/" + relative
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func link(_ relative: String, to destination: String) throws -> String {
        let path = base + "/" + relative
        try fm.createSymbolicLink(atPath: path, withDestinationPath: destination)
        return path
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    // MARK: - Identity

    func testASymlinkedRootIsTheDirectoryItPointsAt() throws {
        let real = try mkdir("claude-work")
        let alias = try link("claude-alias", to: real)
        XCTAssertEqual(ConfigPathIdentity.identity(of: alias), ConfigPathIdentity.identity(of: real))
        XCTAssertNotEqual(ConfigPathIdentity.identity(of: real), ConfigPathIdentity.identity(of: try mkdir("other")))
    }

    /// `~/.Codex-Work` typed by hand is `~/.codex-work` on a case-insensitive
    /// volume (the macOS default).
    func testLetterCaseFollowsTheDisk() throws {
        let real = try mkdir("codex-work")
        let shouted = base + "/CODEX-WORK"
        guard fm.fileExists(atPath: shouted) else {
            throw XCTSkip("case-sensitive volume: the two spellings are different directories")
        }
        XCTAssertEqual(ConfigPathIdentity.identity(of: shouted), ConfigPathIdentity.identity(of: real))
        XCTAssertEqual(
            ConfigPathIdentity.identity(of: shouted + "/hooks.json"),
            ConfigPathIdentity.identity(of: real + "/hooks.json"),
            "a file not written yet still resolves through its folder"
        )
    }

    /// Grok's `hooks/` of an extra root linked to the primary's: the managed
    /// file is the primary's before it exists at all.
    func testAFileNotWrittenYetResolvesThroughASymlinkedFolder() throws {
        let primaryHooks = try mkdir("grok/hooks")
        _ = try mkdir("grok-2")
        _ = try link("grok-2/hooks", to: primaryHooks)
        XCTAssertEqual(
            ConfigPathIdentity.identity(of: base + "/grok-2/hooks/codeisland.json"),
            ConfigPathIdentity.identity(of: primaryHooks + "/codeisland.json")
        )
    }

    func testADanglingSymlinkIsWhereItPoints() throws {
        let primary = try mkdir("claude")
        _ = try mkdir("claude-work")
        // Relative target, file not created yet.
        let settings = try link("claude-work/settings.json", to: "../claude/settings.json")
        XCTAssertEqual(
            ConfigPathIdentity.identity(of: settings),
            ConfigPathIdentity.identity(of: primary + "/settings.json")
        )
    }

    func testASymlinkLoopEndsInsteadOfSpinning() throws {
        let a = try link("loop-a", to: base + "/loop-b")
        _ = try link("loop-b", to: a)
        XCTAssertFalse(ConfigPathIdentity.identity(of: a + "/settings.json").isEmpty)
    }

    func testLexicalNormalization() {
        XCTAssertEqual(ConfigPathIdentity.lexicallyNormalized("/a/./b/../c//d/"), "/a/c/d")
        XCTAssertEqual(ConfigPathIdentity.lexicallyNormalized("/../x"), "/x")
    }

    // MARK: - Writes

    func testWritingThroughASymlinkedFileKeepsTheLink() throws {
        let shared = try mkdir("dotfiles") + "/settings.json"
        XCTAssertTrue(fm.createFile(atPath: shared, contents: Data("{}".utf8)))
        _ = try mkdir("claude-work")
        let settings = try link("claude-work/settings.json", to: shared)

        XCTAssertTrue(ConfigPathIdentity.write(Data(#"{"hooks":{}}"#.utf8), to: settings))

        XCTAssertTrue(isSymlink(settings), "the link survives")
        XCTAssertEqual(try String(contentsOfFile: shared, encoding: .utf8), #"{"hooks":{}}"#)
    }

    /// A link into a read-only store (Nix / home-manager) cannot be written
    /// through; the write then replaces the link as it always did, so the
    /// hooks still land.
    func testALinkIntoAReadOnlyFolderFallsBackToReplacingTheLink() throws {
        let store = try mkdir("store")
        let target = store + "/settings.json"
        XCTAssertTrue(fm.createFile(atPath: target, contents: Data("{}".utf8)))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store) }
        _ = try mkdir("claude")
        let settings = try link("claude/settings.json", to: target)
        guard !fm.createFile(atPath: store + "/probe", contents: Data()) else {
            throw XCTSkip("running with permissions that ignore the read-only folder")
        }

        XCTAssertTrue(ConfigPathIdentity.write(Data(#"{"hooks":{}}"#.utf8), to: settings))

        XCTAssertFalse(isSymlink(settings))
        XCTAssertEqual(try String(contentsOfFile: settings, encoding: .utf8), #"{"hooks":{}}"#)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "{}", "the store is untouched")
    }

    func testAPlainFileIsWrittenInPlace() throws {
        let file = try mkdir("plain") + "/hooks.json"
        XCTAssertEqual(ConfigPathIdentity.writeTarget(for: file), file, "missing file: itself")
        XCTAssertTrue(ConfigPathIdentity.write(Data("{}".utf8), to: file))
        XCTAssertEqual(ConfigPathIdentity.writeTarget(for: file), file)
        XCTAssertFalse(isSymlink(file))
    }

    /// Only the final component is redirected: a symlinked *root* is followed
    /// by the kernel, and writing through it never broke anything.
    func testASymlinkedFolderDoesNotRedirectTheWrite() throws {
        let real = try mkdir("codex-real")
        let alias = try link("codex-alias", to: real)
        XCTAssertEqual(ConfigPathIdentity.writeTarget(for: alias + "/hooks.json"), alias + "/hooks.json")
    }

    // MARK: - Roots and owning root

    /// Codex reports the transcript under the real directory; the root was
    /// registered through a symlink (or with other letter case). It must still
    /// be recognised as that account's, not fall back to the primary.
    func testOwningRootMatchesThroughSymlinksAndCase() throws {
        _ = try mkdir("codex-work/sessions/2026/09/24")
        let alias = try link("codex-link", to: base + "/codex-work")
        let primary = try mkdir("codex")
        let transcript = base + "/codex-work/sessions/2026/09/24/rollout-1.jsonl"
        XCTAssertTrue(fm.createFile(atPath: transcript, contents: Data()))

        XCTAssertEqual(ExtraConfigDirs.owningRoot(of: transcript, among: [primary, alias]), alias)
        // …and the other way round: the CLI ran through the link.
        XCTAssertEqual(
            ExtraConfigDirs.owningRoot(of: alias + "/sessions/2026/09/24/rollout-1.jsonl", among: [primary, base + "/codex-work"]),
            base + "/codex-work"
        )
        if fm.fileExists(atPath: base + "/CODEX-WORK") {
            XCTAssertEqual(ExtraConfigDirs.owningRoot(of: transcript, among: [primary, base + "/CODEX-WORK"]), base + "/CODEX-WORK")
        }
        XCTAssertNil(ExtraConfigDirs.owningRoot(of: base + "/elsewhere/r.jsonl", among: [primary, alias]))
    }

    /// `roots` sits on the per-hook-event path, so it is memoized on the
    /// spellings: a changed disk layout is only seen after invalidation, a
    /// changed configuration at once.
    func testRootsAreMemoizedOnTheirInputs() throws {
        let primary = try mkdir("p")
        let extra = try mkdir("x")
        XCTAssertEqual(ExtraConfigDirs.roots(primary: primary, extras: [extra]), [primary, extra])

        // Replace the extra with a symlink to the primary behind the cache's back.
        try fm.removeItem(atPath: extra)
        try fm.createSymbolicLink(atPath: extra, withDestinationPath: primary)
        XCTAssertEqual(ExtraConfigDirs.roots(primary: primary, extras: [extra]), [primary, extra], "served from the memo")
        XCTAssertEqual(ExtraConfigDirs.roots(primary: primary, extras: [extra, extra + "/"]), [primary], "new inputs, fresh result")

        ExtraConfigDirs.invalidateRootsCache()
        XCTAssertEqual(ExtraConfigDirs.roots(primary: primary, extras: [extra]), [primary])
    }
}
