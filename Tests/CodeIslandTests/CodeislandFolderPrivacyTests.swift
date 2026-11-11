import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// sessions.json holds every local session's last prompt and reply, and a
/// macOS home lets other accounts in: what CodeIsland writes under
/// ~/.codeisland is this user's alone, and what an older build left open
/// there is narrowed at launch. Against a scratch folder, never the user's.
final class CodeislandFolderPrivacyTests: XCTestCase {
    private var scratch: String!

    override func setUpWithError() throws {
        scratch = NSTemporaryDirectory() + "ci-folder-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    private func mode(_ path: String) throws -> mode_t {
        try XCTUnwrap(SocketPath.lstat(path), path).st_mode & 0o777
    }

    private func session() -> SessionSnapshot {
        var session = SessionSnapshot()
        session.cwd = "/tmp/private-folder"
        session.lastUserPrompt = "SECRET-PROMPT"
        session.lastAssistantMessage = "SECRET-REPLY"
        return session
    }

    // MARK: - sessions.json

    func testTheSessionsFileAndItsFolderAreThisUsersAlone() throws {
        let dir = scratch + "/.codeisland"
        SessionPersistence.save(["s1": session()], directory: dir)
        let file = dir + "/sessions.json"
        let contents = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(contents.contains("SECRET-PROMPT") && contents.contains("SECRET-REPLY"))
        XCTAssertEqual(try mode(file), 0o600, "sessions.json must not be readable by other accounts")
        XCTAssertEqual(try mode(dir), 0o700, "its folder must not let other accounts in")
    }

    func testEverySaveKeepsTheFilePrivate() throws {
        let dir = scratch + "/.codeisland"
        XCTAssertEqual(mkdir(dir, 0o755), 0)
        XCTAssertEqual(chmod(dir, 0o755), 0)
        let file = dir + "/sessions.json"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data("[]".utf8)))
        XCTAssertEqual(chmod(file, 0o644), 0)

        SessionPersistence.save(["s1": session()], directory: dir)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)
        SessionPersistence.save(["s1": session(), "s2": session()], directory: dir)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(SessionPersistence.load(directory: dir).count, 2)
    }

    func testLaunchNarrowsWhatAnOlderBuildLeftOpen() throws {
        let dir = scratch + "/.codeisland"
        SessionPersistence.save(["s1": session()], directory: dir)
        let file = dir + "/sessions.json"
        XCTAssertEqual(chmod(dir, 0o755), 0)
        XCTAssertEqual(chmod(file, 0o644), 0)

        XCTAssertEqual(SessionPersistence.load(directory: dir).map(\.sessionId), ["s1"])
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testLaunchDoesNotFollowASymlinkedSessionsFile() throws {
        let dir = scratch + "/.codeisland"
        XCTAssertEqual(mkdir(dir, 0o700), 0)
        let target = scratch + "/elsewhere.json"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("[]".utf8)))
        XCTAssertEqual(chmod(target, 0o644), 0)
        try FileManager.default.createSymbolicLink(atPath: dir + "/sessions.json", withDestinationPath: target)

        _ = SessionPersistence.load(directory: dir)
        XCTAssertEqual(try mode(target), 0o644)
        SessionPersistence.save(["s1": session()], directory: dir)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "[]", "written through the link")
        XCTAssertEqual(try mode(dir + "/sessions.json"), 0o600)
    }

    // MARK: - The hook script and the bridge

    func testTheFolderAndWhatAnOlderBuildPutInItAreNarrowed() throws {
        let dir = scratch + "/.codeisland"
        XCTAssertEqual(mkdir(dir, 0o755), 0)
        XCTAssertEqual(chmod(dir, 0o755), 0)
        let modes: [String: mode_t] = [
            "codeisland-hook.sh": 0o755, "codeisland-bridge": 0o755, "sessions.json": 0o644,
        ]
        for (name, old) in modes {
            XCTAssertTrue(FileManager.default.createFile(atPath: dir + "/" + name, contents: Data("x".utf8)))
            XCTAssertEqual(chmod(dir + "/" + name, old), 0)
        }

        ConfigInstaller.prepareCodeislandDir(dir)
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(dir + "/codeisland-hook.sh"), 0o700)
        XCTAssertEqual(try mode(dir + "/codeisland-bridge"), 0o700)
        XCTAssertEqual(try mode(dir + "/sessions.json"), 0o600)
    }

    func testTheFolderIsMadeForThisUserAlone() throws {
        let dir = scratch + "/.codeisland"
        ConfigInstaller.prepareCodeislandDir(dir)
        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testTheHookScriptIsWrittenForThisUserToRun() throws {
        let script = scratch + "/codeisland-hook.sh"
        ConfigInstaller.installHookScript(fm: .default, path: script)
        XCTAssertEqual(try mode(script), 0o700)
        XCTAssertEqual(try String(contentsOfFile: script, encoding: .utf8), ConfigInstaller.hookScript)
    }

    /// v1.0.39 left its v5 script 0755: the update replaces it, owner-only.
    func testTheHookScriptAnOlderBuildWroteIsReplacedForThisUserAlone() throws {
        let script = scratch + "/codeisland-hook.sh"
        let older = "#!/bin/bash\n# CodeIsland hook v5 — native bridge with shell fallback\nSOCK=\"/tmp/codeisland-$(id -u).sock\"\n[ -S \"$SOCK\" ] || exit 0\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: script, contents: Data(older.utf8)))
        XCTAssertEqual(chmod(script, 0o755), 0)
        ConfigInstaller.installHookScript(fm: .default, path: script)
        XCTAssertEqual(try String(contentsOfFile: script, encoding: .utf8), ConfigInstaller.hookScript)
        XCTAssertEqual(try mode(script), 0o700)
    }

    func testACurrentHookScriptLeftOpenIsNarrowed() throws {
        let script = scratch + "/codeisland-hook.sh"
        XCTAssertTrue(FileManager.default.createFile(atPath: script, contents: Data(ConfigInstaller.hookScript.utf8)))
        XCTAssertEqual(chmod(script, 0o755), 0)
        ConfigInstaller.installHookScript(fm: .default, path: script)
        XCTAssertEqual(try mode(script), 0o700)
    }
}
