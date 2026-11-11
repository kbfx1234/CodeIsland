import XCTest
@testable import CodeIslandCore

final class AppDistributionTests: XCTestCase {
    // MARK: - Release notes link

    func testReleaseNotesPointAtTheVersionTag() {
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: "1.0.34").absoluteString,
            "https://github.com/wxtsky/CodeIsland/releases/tag/v1.0.34"
        )
    }

    func testAlreadyPrefixedOrPaddedVersionsAreNotDoublePrefixed() {
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: " v1.0.34\n").absoluteString,
            "https://github.com/wxtsky/CodeIsland/releases/tag/v1.0.34"
        )
    }

    func testPrereleaseSuffixIsKept() {
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: "1.1.0-beta.2").absoluteString,
            "https://github.com/wxtsky/CodeIsland/releases/tag/v1.1.0-beta.2"
        )
    }

    func testUnusableVersionFallsBackToTheReleaseList() {
        for bad in ["", "   ", "dev build", "../../evil", "1.0/2"] {
            XCTAssertEqual(
                ReleaseNotesLink.url(forVersion: bad).absoluteString,
                "https://github.com/wxtsky/CodeIsland/releases",
                "\"\(bad)\""
            )
        }
    }

    // MARK: - Read-only install location

    func testNormalInstallIsNotFlagged() {
        XCTAssertNil(AppInstallLocation.readOnlyReason(
            bundlePath: "/Applications/CodeIsland.app", volumeIsReadOnly: false))
        XCTAssertNil(AppInstallLocation.readOnlyReason(
            bundlePath: "/Users/me/Applications/CodeIsland.app", volumeIsReadOnly: false))
    }

    func testTranslocatedCopyIsFlaggedEvenThoughItsMountIsReadOnly() {
        let path = "/private/var/folders/xy/abc/T/AppTranslocation/1F2E3D4C-0000-1111-2222-333344445555/d/CodeIsland.app"
        XCTAssertEqual(AppInstallLocation.readOnlyReason(bundlePath: path, volumeIsReadOnly: true), .translocated)
        XCTAssertEqual(AppInstallLocation.readOnlyReason(bundlePath: path, volumeIsReadOnly: false), .translocated)
    }

    func testRunningFromTheMountedDiskImageIsFlagged() {
        XCTAssertEqual(
            AppInstallLocation.readOnlyReason(bundlePath: "/Volumes/CodeIsland/CodeIsland.app", volumeIsReadOnly: true),
            .diskImage
        )
    }

    /// An external drive under /Volumes that *is* writable updates fine.
    func testWritableExternalVolumeIsNotFlagged() {
        XCTAssertNil(AppInstallLocation.readOnlyReason(
            bundlePath: "/Volumes/External/Apps/CodeIsland.app", volumeIsReadOnly: false))
    }

    func testOtherReadOnlyVolumeIsFlagged() {
        XCTAssertEqual(
            AppInstallLocation.readOnlyReason(bundlePath: "/Applications/CodeIsland.app", volumeIsReadOnly: true),
            .readOnlyVolume
        )
    }
}
