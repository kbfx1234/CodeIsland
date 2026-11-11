import XCTest
@testable import CodeIsland

/// The boot jingle confirms a launch the user just made by hand. A login-item
/// launch — or one the system restores at login — must stay silent.
final class LaunchContextTests: XCTestCase {
    func testAppleEventLoginItemFlagWinsOnItsOwn() {
        XCTAssertTrue(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: true,
            secondsSinceSessionStart: 3_600,
            secondsSinceBoot: 86_400
        ))
    }

    func testLaunchRightAfterLoginCountsWithoutTheAppleEvent() {
        // SMAppService items and "reopen windows" relaunches may not carry
        // keyAELaunchedAsLogInItem.
        XCTAssertTrue(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: false,
            secondsSinceSessionStart: 25,
            secondsSinceBoot: 86_400
        ))
    }

    func testHandLaunchLongAfterLoginPlaysTheJingle() {
        XCTAssertFalse(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: false,
            secondsSinceSessionStart: 2 * 3_600,
            secondsSinceBoot: 30
        ), "a known session age overrides the uptime fallback")
    }

    func testWindowIsHalfOpen() {
        let window = LaunchContext.loginWindow
        XCTAssertTrue(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: false, secondsSinceSessionStart: window - 1, secondsSinceBoot: 1e6))
        XCTAssertFalse(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: false, secondsSinceSessionStart: window, secondsSinceBoot: 1e6))
    }

    func testNegativeSessionAgeIsNotALoginLaunch() {
        XCTAssertFalse(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: false,
            secondsSinceSessionStart: -30,
            secondsSinceBoot: 1e6
        ))
    }

    func testUnknownSessionFallsBackToUptime() {
        XCTAssertTrue(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: false, secondsSinceSessionStart: nil, secondsSinceBoot: 40))
        XCTAssertFalse(LaunchContext.isLoginLaunch(
            launchedAsLoginItem: false, secondsSinceSessionStart: nil, secondsSinceBoot: 7_200))
    }

    /// The utmpx reader must not crash and, when it answers, must answer with
    /// a time in the past (the test runner lives inside a GUI session on a dev
    /// Mac but not necessarily on CI).
    func testConsoleSessionStartIsInThePastWhenKnown() {
        if let start = LaunchContext.consoleSessionStart() {
            XCTAssertLessThanOrEqual(start, Date())
        }
        XCTAssertNil(LaunchContext.consoleSessionStart(user: "no-such-user-\(UUID().uuidString)"))
    }

    @MainActor
    func testNoAppleEventOutsideLaunchMeansNotALoginItem() {
        XCTAssertFalse(LaunchContext.launchedAsLoginItemFromAppleEvent())
    }
}
