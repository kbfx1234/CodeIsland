import XCTest
@testable import CodeIsland

/// Regression: async XCTest / background ARC must be able to release AppState
/// without trapping in deinit (previous MainActor.assumeIsolated path), including
/// when session discovery's FSEventStream was started.
final class AppStateDeinitTests: XCTestCase {
    func testDeinitOffMainActorAfterDiscoveryDoesNotTrap() async {
        final class Holder: @unchecked Sendable {
            var state: AppState?
        }
        let holder = Holder()
        await MainActor.run {
            let state = AppState()
            // A test process watches no session store unless told to: give
            // the watcher a root so there is an FSEventStream to tear down.
            let root = NSTemporaryDirectory()
            state.discovery.scanners.watchRoots = { [root] }
            state.startSessionDiscovery()
            holder.state = state
        }

        await Task.detached {
            holder.state = nil
        }.value

        // Give the main-queue box drain a turn so teardown completes cleanly.
        await MainActor.run { }
    }
}
