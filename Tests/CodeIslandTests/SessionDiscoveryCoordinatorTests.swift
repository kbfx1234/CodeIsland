import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// How the discovery coordinator schedules scans: one at a time, requests
/// made during one collapsed into one rescan, nothing left running or
/// landing after `stop()`, and the cleanup tick's Codex Desktop poll.
@MainActor
final class SessionDiscoveryCoordinatorTests: XCTestCase {
    /// A scanner that blocks until its gate opens, counting the scans that
    /// ran and the most that ran at once.
    private func gatedScanners(_ scans: ScanCounter, gates: [ScanGate]) -> SessionDiscoveryCoordinator.Scanners {
        var scanners = SessionDiscoveryCoordinator.Scanners.inert
        scanners.sessions = {
            let n = scans.begin()
            gates[min(n, gates.count) - 1].wait()
            scans.end()
            return []
        }
        return scanners
    }

    func testRequestsDuringAScanCollapseIntoOneRescan() async throws {
        let gate = ScanGate()
        defer { gate.open() }
        let scans = ScanCounter()
        let coordinator = SessionDiscoveryCoordinator(scanners: gatedScanners(scans, gates: [gate]))
        var landed = 0
        coordinator.onDiscovered = { _ in landed += 1 }

        coordinator.requestScan()
        await waitUntil("the first scan never started") { scans.started == 1 }
        coordinator.requestScan()
        coordinator.requestScan()
        coordinator.requestScan()
        gate.open()
        await waitUntil("the rescan never landed") { landed == 2 }
        coordinator.requestScan()
        await waitUntil("a request after both landed never scanned") { landed == 3 }
        XCTAssertEqual(scans.started, 3, "one scan, one rescan for the three requests made during it, one more")
        XCTAssertEqual(scans.mostAtOnce, 1)
    }

    func testStopDropsTheScanInFlightAndItsRescan() async throws {
        let gate = ScanGate()
        defer { gate.open() }
        let scans = ScanCounter()
        let coordinator = SessionDiscoveryCoordinator(scanners: gatedScanners(scans, gates: [gate]))
        var landed = 0
        coordinator.onDiscovered = { _ in landed += 1 }

        coordinator.requestScan()
        await waitUntil("the scan never started") { scans.started == 1 }
        coordinator.requestScan()
        coordinator.stop()
        gate.open()
        await waitUntil("the scan never finished") { scans.finished == 1 }
        // Its hop to the main actor is queued behind this one: yield until
        // the main actor had the chance to run it.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(landed, 0, "what a stopped scan found is dropped")
        XCTAssertEqual(scans.started, 1, "and the rescan asked for during it never runs")
    }

    /// A scan stop() cancelled that lands after a new one started leaves the
    /// new scan's handle alone: the next request still waits for it.
    func testAScanFromBeforeStopLeavesTheNextScansHandleAlone() async throws {
        let first = ScanGate()
        let later = ScanGate()
        defer { first.open(); later.open() }
        let scans = ScanCounter()
        let coordinator = SessionDiscoveryCoordinator(scanners: gatedScanners(scans, gates: [first, later]))
        var landed = 0
        coordinator.onDiscovered = { _ in landed += 1 }

        coordinator.requestScan()
        await waitUntil("the first scan never started") { scans.started == 1 }
        // The first scan finishes while the main actor is busy: its hop to
        // the main actor waits behind this test.
        first.open()
        Thread.sleep(forTimeInterval: 0.2)
        coordinator.stop()
        coordinator.start()
        await waitUntil("the second scan never started") { scans.started == 2 }
        for _ in 0..<20 { await Task.yield() }
        coordinator.requestScan()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(scans.started, 2, "the request waits for the running scan")
        XCTAssertEqual(scans.mostAtOnce, 1)

        later.open()
        await waitUntil("the rescan never landed") { landed == 2 }
        XCTAssertEqual(scans.started, 3)
    }

    func testNothingStartsAfterStopUntilStart() async throws {
        let scans = ScanCounter()
        var scanners = SessionDiscoveryCoordinator.Scanners.inert
        scanners.sessions = { scans.begin(); scans.end(); return [] }
        scanners.codexDesktopSessions = { scans.begin(); scans.end(); return [] }
        let coordinator = SessionDiscoveryCoordinator(scanners: scanners)
        var landed = 0
        coordinator.onDiscovered = { _ in landed += 1 }

        coordinator.stop()
        // A cleanup tick or watcher event queued before stop() lands after it.
        coordinator.requestScan()
        coordinator.requestCodexDesktopScan()
        coordinator.pollCodexDesktopIfDue(now: Date()) { [AppState.codexAppBundleId] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(scans.started, 0)

        coordinator.start()
        await waitUntil("start() never scanned") { landed == 1 }
        XCTAssertEqual(scans.started, 1)
    }

    /// The cleanup tick asks every 3 s; Codex Desktop is polled at most every
    /// 6 s, only while it runs, and the running-app list (a LaunchServices
    /// round trip) is only built once the interval has passed.
    func testCodexDesktopPollCadence() async throws {
        let scans = ScanCounter()
        var scanners = SessionDiscoveryCoordinator.Scanners.inert
        scanners.codexDesktopSessions = { scans.begin(); scans.end(); return [] }
        let coordinator = SessionDiscoveryCoordinator(scanners: scanners)
        var landed = 0
        coordinator.onDiscovered = { _ in landed += 1 }
        var appListsBuilt = 0
        func codexRunning() -> Set<String> {
            appListsBuilt += 1
            return [AppState.codexAppBundleId]
        }
        let t0 = Date()

        coordinator.pollCodexDesktopIfDue(now: t0, runningBundleIdentifiers: codexRunning)
        await waitUntil("the first poll never scanned") { landed == 1 }
        coordinator.pollCodexDesktopIfDue(now: t0.addingTimeInterval(3), runningBundleIdentifiers: codexRunning)
        XCTAssertEqual(appListsBuilt, 1, "3 s later the app list is not even built")
        coordinator.pollCodexDesktopIfDue(now: t0.addingTimeInterval(6), runningBundleIdentifiers: codexRunning)
        await waitUntil("the poll 6 s later never scanned") { landed == 2 }
        XCTAssertEqual(appListsBuilt, 2)
        XCTAssertEqual(scans.started, 2)

        coordinator.pollCodexDesktopIfDue(now: t0.addingTimeInterval(12)) { [] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(scans.started, 2, "no poll while Codex Desktop is not running")
    }
}

private final class ScanGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    func wait() {
        _ = semaphore.wait(timeout: .now() + asyncTestTimeout)
        semaphore.signal()
    }

    func open() {
        lock.withLock {
            guard !opened else { return }
            opened = true
            semaphore.signal()
        }
    }
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = 0
    private var _finished = 0
    private var running = 0
    private var _mostAtOnce = 0

    /// Counts a scan starting; returns its number (1 for the first).
    @discardableResult
    func begin() -> Int {
        lock.withLock {
            _started += 1
            running += 1
            _mostAtOnce = max(_mostAtOnce, running)
            return _started
        }
    }

    func end() {
        lock.withLock {
            running -= 1
            _finished += 1
        }
    }

    var started: Int { lock.withLock { _started } }
    var finished: Int { lock.withLock { _finished } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
}
