import Darwin
import XCTest
@testable import CodeIslandCore

/// What CodeIsland keeps under ~/.codeisland is this user's alone: folders
/// 0700, files 0600 (0700 for what agents run), never through a symlink and
/// never what another user owns. Against a scratch folder of the test's.
final class PrivateFilesTests: XCTestCase {
    private var scratch: String!

    override func setUpWithError() throws {
        scratch = NSTemporaryDirectory() + "ci-private-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    private func mode(_ path: String) throws -> mode_t {
        try XCTUnwrap(SocketPath.lstat(path), path).st_mode & 0o7777
    }

    private func makeFile(_ path: String, _ contents: String = "x", mode: mode_t) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(contents.utf8)))
        XCTAssertEqual(chmod(path, mode), 0)
    }

    // MARK: - Folders

    func testAFolderIsCreatedForThisUserAloneParentsToo() throws {
        let parent = scratch + "/a"
        let folder = parent + "/b"
        XCTAssertTrue(PrivateFiles.prepareFolder(folder))
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try mode(parent), 0o700)
    }

    func testAnOpenFolderOfThisUsersIsNarrowed() throws {
        let folder = scratch + "/open"
        XCTAssertEqual(mkdir(folder, 0o755), 0)
        XCTAssertEqual(chmod(folder, 0o755), 0)
        XCTAssertTrue(PrivateFiles.prepareFolder(folder))
        XCTAssertEqual(try mode(folder), 0o700)
    }

    func testASymlinkToAFolderIsNotFollowed() throws {
        let real = scratch + "/real"
        XCTAssertEqual(mkdir(real, 0o755), 0)
        XCTAssertEqual(chmod(real, 0o755), 0)
        let link = scratch + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertFalse(PrivateFiles.prepareFolder(link))
        XCTAssertFalse(PrivateFiles.closeToOthers(link))
        XCTAssertEqual(try mode(real), 0o755)
    }

    func testAFolderOfSomeoneElsesIsLeftAlone() throws {
        let folder = scratch + "/theirs"
        XCTAssertEqual(mkdir(folder, 0o755), 0)
        XCTAssertEqual(chmod(folder, 0o755), 0)
        XCTAssertFalse(PrivateFiles.prepareFolder(folder, uid: getuid() + 1))
        XCTAssertEqual(try mode(folder), 0o755)
    }

    func testAFileWhereTheFolderGoesIsNotAFolder() throws {
        let path = scratch + "/file"
        try makeFile(path, mode: 0o644)
        XCTAssertFalse(PrivateFiles.prepareFolder(path))
    }

    // MARK: - Files already there

    func testAFileKeepsItsOwnersBitsAndLosesEveryoneElses() throws {
        let data = scratch + "/sessions.json"
        let script = scratch + "/hook.sh"
        try makeFile(data, mode: 0o644)
        try makeFile(script, mode: 0o755)
        XCTAssertTrue(PrivateFiles.closeToOthers(data))
        XCTAssertTrue(PrivateFiles.closeToOthers(script))
        XCTAssertEqual(try mode(data), 0o600)
        XCTAssertEqual(try mode(script), 0o700)
    }

    func testASymlinkToAFileIsNotFollowed() throws {
        let target = scratch + "/zshrc"
        try makeFile(target, mode: 0o644)
        let link = scratch + "/sessions.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertFalse(PrivateFiles.closeToOthers(link))
        XCTAssertEqual(try mode(target), 0o644)
    }

    func testAFileOfSomeoneElsesIsLeftAlone() throws {
        let path = scratch + "/theirs.json"
        try makeFile(path, mode: 0o644)
        XCTAssertFalse(PrivateFiles.closeToOthers(path, uid: getuid() + 1))
        XCTAssertEqual(try mode(path), 0o644)
    }

    func testAFIFOIsLeftAloneWithoutHanging() throws {
        let path = scratch + "/fifo"
        XCTAssertEqual(mkfifo(path, 0o644), 0)
        XCTAssertEqual(chmod(path, 0o644), 0)
        XCTAssertFalse(PrivateFiles.closeToOthers(path))
        XCTAssertEqual(try mode(path), 0o644)
    }

    func testNothingThereIsNotClosed() {
        XCTAssertFalse(PrivateFiles.closeToOthers(scratch + "/missing"))
    }

    // MARK: - Writing

    func testAWrittenFileIsThisUsersAloneWhateverTheUmask() throws {
        let path = scratch + "/sessions.json"
        let previous = umask(0)
        defer { umask(previous) }
        try PrivateFiles.write(Data("SECRET".utf8), to: path)
        XCTAssertEqual(try mode(path), 0o600)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "SECRET")
    }

    func testRewritingAnOpenFileReplacesItWithAPrivateOne() throws {
        let path = scratch + "/sessions.json"
        try makeFile(path, "old", mode: 0o644)
        try PrivateFiles.write(Data("new".utf8), to: path)
        XCTAssertEqual(try mode(path), 0o600)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "new")
    }

    func testAnExecutableIsWrittenForItsOwnerToRun() throws {
        let path = scratch + "/hook.sh"
        try PrivateFiles.write(Data("#!/bin/sh\n".utf8), to: path, mode: 0o700)
        XCTAssertEqual(try mode(path), 0o700)
    }

    func testWritingReplacesASymlinkInsteadOfWritingThroughIt() throws {
        let target = scratch + "/zshrc"
        try makeFile(target, "untouched", mode: 0o644)
        let path = scratch + "/sessions.json"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        try PrivateFiles.write(Data("new".utf8), to: path)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "untouched")
        XCTAssertEqual(try mode(target), 0o644)
        let info = try XCTUnwrap(SocketPath.lstat(path))
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testAFailedWriteLeavesNoTempFileBehind() throws {
        let folder = scratch + "/folder"
        XCTAssertEqual(mkdir(folder, 0o700), 0)
        // A folder where the file goes: the rename fails.
        XCTAssertThrowsError(try PrivateFiles.write(Data("x".utf8), to: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch), ["folder"])
    }
}
