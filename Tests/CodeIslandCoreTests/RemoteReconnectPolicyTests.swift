import XCTest
@testable import CodeIslandCore

final class RemoteReconnectPolicyTests: XCTestCase {
    private typealias Step = RemoteReconnectPolicy.Step

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// An auto-connect host "a" that failed `failures` times in a row and has
    /// a retry pending.
    private func failing(_ failures: Int, online: Bool? = true) -> RemoteReconnectPolicy {
        var p = RemoteReconnectPolicy()
        if let online { _ = p.networkChanged(satisfied: online) }
        _ = p.userConnected("a")
        for n in 1...failures {
            _ = p.tunnelFailed("a", autoRetry: true, now: at(Double(n)))
            if n < failures { XCTAssertEqual(p.retryDue("a"), .connect) }
        }
        return p
    }

    // MARK: Backoff

    func testBackoffFollowsTheTable() {
        let c = RemoteReconnectPolicy.Config()
        XCTAssertEqual(c.delay(forAttempt: 1), 5)
        XCTAssertEqual(c.delay(forAttempt: 2), 15)
        XCTAssertEqual(c.delay(forAttempt: 3), 45)
        XCTAssertEqual(c.delay(forAttempt: 4), 120)
        XCTAssertEqual(c.delay(forAttempt: 5), 300)
    }

    func testBackoffClampsBeyondTheTable() {
        let c = RemoteReconnectPolicy.Config()
        XCTAssertEqual(c.delay(forAttempt: 6), 300)
        XCTAssertEqual(c.delay(forAttempt: 100), 300)
    }

    func testBackoffNeverReturnsLessThanTheFirstStepForBogusInput() {
        let c = RemoteReconnectPolicy.Config()
        XCTAssertEqual(c.delay(forAttempt: 0), 5)
        XCTAssertEqual(c.delay(forAttempt: -1), 5)
    }

    /// Ten fast retries, then one every 15 minutes: never a permanent give-up.
    func testRetriesSlowDownInsteadOfGivingUp() {
        var p = RemoteReconnectPolicy()
        _ = p.userConnected("a")
        var steps: [Step] = []
        for n in 1...12 {
            steps.append(p.tunnelFailed("a", autoRetry: true, now: at(Double(n))))
            XCTAssertEqual(p.phase(of: "a"), .retryPending)
            XCTAssertEqual(p.retryDue("a"), .connect)
        }
        XCTAssertEqual(steps[0], .retry(delay: 5, attempt: 1))
        XCTAssertEqual(steps[4], .retry(delay: 300, attempt: 5))
        XCTAssertEqual(steps[9], .retry(delay: 300, attempt: 10))
        XCTAssertEqual(steps[10], .retrySlowly(delay: 900, failures: 11))
        XCTAssertEqual(steps[11], .retrySlowly(delay: 900, failures: 12))
    }

    /// ssh counts as up before it has reached the host, so a tunnel that dies
    /// right after "connecting" is another failed attempt; one that held for
    /// a while starts the backoff over.
    func testQuickDropsKeepCountingAndAStableTunnelStartsOver() {
        var p = RemoteReconnectPolicy()
        _ = p.userConnected("a")
        p.tunnelConnected("a", now: at(0))
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(1)), .retry(delay: 5, attempt: 1))
        XCTAssertEqual(p.retryDue("a"), .connect)
        p.tunnelConnected("a", now: at(10))
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(85)), .retry(delay: 15, attempt: 2))
        XCTAssertEqual(p.retryDue("a"), .connect)
        p.tunnelConnected("a", now: at(100))
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(100 + 120)), .retry(delay: 5, attempt: 1))
    }

    // MARK: Wake (#375)

    /// The lid stayed shut long enough for every fast retry to fail in dark
    /// wakes; opening it brings the host back on a fresh backoff.
    func testWakeAfterTheRetriesRanOutReconnects() {
        var p = failing(10)
        XCTAssertEqual(p.retryDue("a"), .connect)
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(11)), .retrySlowly(delay: 900, failures: 11))

        p.systemWoke()
        XCTAssertEqual(p.recover(), ["a": .connect])
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(20)), .retry(delay: 5, attempt: 1))
    }

    /// A retry minutes away is pulled forward to now, and the timer that was
    /// pending no longer does anything when it fires.
    func testWakeWhileARetryIsPendingConnectsNow() {
        var p = failing(5)
        XCTAssertEqual(p.phase(of: "a"), .retryPending)
        XCTAssertEqual(p.failures(of: "a"), 5)

        p.systemWoke()
        XCTAssertEqual(p.failures(of: "a"), 0)
        XCTAssertEqual(p.recover(), ["a": .connect])
        XCTAssertEqual(p.phase(of: "a"), .connecting)
        XCTAssertEqual(p.retryDue("a"), .none, "the old timer is stale")
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(30)), .retry(delay: 5, attempt: 1))
    }

    /// Woken with Wi-Fi still down: no attempt is spent until the path is back.
    func testOfflineAtWakeWaitsForTheNetwork() {
        var p = failing(3)
        XCTAssertFalse(p.networkChanged(satisfied: false))

        p.systemWoke()
        XCTAssertEqual(p.recover(), ["a": .waitForNetwork(recheck: 300)])
        XCTAssertEqual(p.phase(of: "a"), .waitingForNetwork)

        XCTAssertTrue(p.networkChanged(satisfied: true), "the network coming back is due a recovery")
        XCTAssertEqual(p.recover(), ["a": .connect])
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(40)), .retry(delay: 5, attempt: 1))
    }

    /// Still up at wake: left to ssh's keepalives rather than bounced. When
    /// they drop it, the retry starts at the short first step.
    func testConnectedHostIsLeftAloneAtWake() {
        var p = RemoteReconnectPolicy()
        _ = p.userConnected("a")
        p.tunnelConnected("a", now: t0)

        p.systemWoke()
        XCTAssertEqual(p.recover(), [:])
        XCTAssertEqual(p.phase(of: "a"), .connected(since: t0))
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(8 * 3600)), .retry(delay: 5, attempt: 1))
    }

    // MARK: User intent

    /// Disconnect is the user's call: no wake, network change or stale timer
    /// brings the host back.
    func testUserDisconnectedHostStaysDown() {
        var p = RemoteReconnectPolicy()
        _ = p.networkChanged(satisfied: true)
        _ = p.userConnected("a")
        p.tunnelConnected("a", now: t0)
        p.userDisconnected("a")
        XCTAssertFalse(p.wantsConnection("a"))

        p.systemWoke()
        XCTAssertEqual(p.recover(), [:])
        XCTAssertFalse(p.networkChanged(satisfied: false))
        XCTAssertTrue(p.networkChanged(satisfied: true))
        XCTAssertEqual(p.recover(), [:])
        XCTAssertEqual(p.retryDue("a"), .none)
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(1)), .none)
        XCTAssertEqual(p.phase(of: "a"), .idle)
    }

    /// A host connected by hand is restored after sleep too, but a failure
    /// alone never schedules a timer for it: a typo is not retried on a clock.
    func testManualHostComesBackOnWakeButNotOnATimer() {
        var p = RemoteReconnectPolicy()
        _ = p.userConnected("m")
        p.tunnelConnected("m", now: t0)
        XCTAssertEqual(p.tunnelFailed("m", autoRetry: false, now: at(600)), .none)
        XCTAssertEqual(p.phase(of: "m"), .idle)
        XCTAssertTrue(p.wantsConnection("m"))

        p.systemWoke()
        XCTAssertEqual(p.recover(), ["m": .connect])
        XCTAssertEqual(p.tunnelFailed("m", autoRetry: false, now: at(700)), .none)
    }

    func testRemovedHostIsForgotten() {
        var p = failing(2)
        p.forget("a")
        XCTAssertFalse(p.wantsConnection("a"))
        XCTAssertEqual(p.recover(), [:])
        XCTAssertEqual(p.retryDue("a"), .none)
    }

    // MARK: No duplicates

    /// A burst of wake and network events while connects are in flight
    /// starts nothing more: one connect per host, whatever the order.
    func testConnectingHostIsNotStartedTwice() {
        var p = RemoteReconnectPolicy()
        _ = p.networkChanged(satisfied: true)
        _ = p.userConnected("a")
        _ = p.userConnected("b")
        _ = p.tunnelFailed("b", autoRetry: true, now: t0)

        p.systemWoke()
        XCTAssertEqual(p.recover(), ["b": .connect], "a is still connecting")

        XCTAssertFalse(p.networkChanged(satisfied: false))
        XCTAssertTrue(p.networkChanged(satisfied: true))
        p.systemWoke()
        XCTAssertEqual(p.recover(), [:], "both are connecting now")
        XCTAssertEqual(p.recover(), [:])
        XCTAssertEqual(p.retryDue("a"), .none)
        XCTAssertEqual(p.retryDue("b"), .none)
    }

    /// A connect the network went away under still finishes on its own; the
    /// wake that follows doesn't stack another one on it, but its failure now
    /// counts from the first step.
    func testWakeResetsTheBackoffOfAConnectInFlight() {
        var p = failing(6)
        XCTAssertEqual(p.retryDue("a"), .connect)
        p.systemWoke()
        XCTAssertEqual(p.recover(), [:])
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(50)), .retry(delay: 5, attempt: 1))
    }

    // MARK: Network

    /// The monitor's first report only sets the starting point, and only a
    /// return from offline is due a recovery.
    func testOnlyTheNetworkComingBackTriggersRecovery() {
        var p = RemoteReconnectPolicy()
        XCTAssertNil(p.networkSatisfied)
        XCTAssertFalse(p.networkChanged(satisfied: true), "first report")
        XCTAssertFalse(p.networkChanged(satisfied: true), "no change")
        XCTAssertFalse(p.networkChanged(satisfied: false))
        XCTAssertFalse(p.networkChanged(satisfied: false))
        XCTAssertTrue(p.networkChanged(satisfied: true))

        var offlineAtLaunch = RemoteReconnectPolicy()
        XCTAssertFalse(offlineAtLaunch.networkChanged(satisfied: false), "first report")
        XCTAssertTrue(offlineAtLaunch.networkChanged(satisfied: true))
    }

    /// Offline, failures don't use up attempts; when the network returns the
    /// host starts from the first step.
    func testFailuresWhileOfflineDoNotUseUpAttempts() {
        var p = failing(2)
        XCTAssertFalse(p.networkChanged(satisfied: false))
        XCTAssertEqual(p.retryDue("a"), .waitForNetwork(recheck: 300), "due while offline: wait instead")
        for n in 1...3 {
            XCTAssertEqual(p.retryDue("a"), .connect, "the re-check tries anyway")
            XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(Double(100 * n))), .waitForNetwork(recheck: 300))
        }
        XCTAssertEqual(p.failures(of: "a"), 2)

        XCTAssertTrue(p.networkChanged(satisfied: true))
        XCTAssertEqual(p.recover(), ["a": .connect])
        XCTAssertEqual(p.tunnelFailed("a", autoRetry: true, now: at(500)), .retry(delay: 5, attempt: 1))
    }

    /// Before the monitor's first report the network counts as up, so a
    /// launch-time failure retries as before.
    func testUnknownNetworkCountsAsOnline() {
        var p = failing(1, online: nil)
        XCTAssertEqual(p.phase(of: "a"), .retryPending)
        XCTAssertEqual(p.retryDue("a"), .connect)
    }
}
