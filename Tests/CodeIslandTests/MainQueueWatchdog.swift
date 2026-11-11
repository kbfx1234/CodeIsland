import XCTest

/// Turns "the whole `swift test` run hangs forever" into a failure that names
/// the test.
///
/// A background thread pings the main queue every second. XCTest runs every
/// test from the main thread and spins its run loop while an async test
/// waits, so the main queue only stays silent for long when something wedged
/// it — the stalls behind f0875fe, where the run sat until someone killed it.
/// After `limit` without an answer the watchdog prints the test that was
/// running and aborts: `swift test` then fails with a signal, and the crash
/// report (~/Library/Logs/DiagnosticReports) holds the main thread's stack.
final class MainQueueWatchdog: NSObject, XCTestObservation {
    static let limit: TimeInterval = 30

    private static let shared = MainQueueWatchdog()

    private let lock = NSLock()
    private var lastAnswer = ProcessInfo.processInfo.systemUptime
    private var runningTest: String?
    private var started = false

    /// Starts the watchdog for the rest of the process; later calls do
    /// nothing. Call on the main thread (XCTest's observer list lives there).
    static func startOnce() {
        shared.start()
    }

    static var isRunning: Bool {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.started
    }

    private func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lastAnswer = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        XCTestObservationCenter.shared.addTestObserver(self)
        let thread = Thread { [self] in watch() }
        thread.name = "MainQueueWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: 1)
            DispatchQueue.main.async { [self] in
                lock.lock()
                lastAnswer = ProcessInfo.processInfo.systemUptime
                lock.unlock()
            }

            lock.lock()
            let silence = ProcessInfo.processInfo.systemUptime - lastAnswer
            let test = runningTest
            lock.unlock()
            guard silence > Self.limit else { continue }

            let message = """

            MainQueueWatchdog: the main queue has not run anything for \(Int(silence)) s \
            while running \(test ?? "no test (between tests)"). Aborting so the run fails \
            here instead of hanging; the crash report has the main thread's stack.

            """
            FileHandle.standardError.write(Data(message.utf8))
            abort()
        }
    }

    // MARK: XCTestObservation (main thread)

    func testCaseWillStart(_ testCase: XCTestCase) {
        lock.lock()
        runningTest = testCase.name
        lock.unlock()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock()
        runningTest = nil
        lock.unlock()
    }
}

/// Starts the watchdog. While XCTest assembles a full run it asks every test
/// class for its `defaultTestSuite` before the first test starts, so this
/// override arms the whole bundle without a shared base class (SwiftPM test
/// bundles have no principal class to register an observer from). A filtered
/// run (`swift test --filter`) builds only the selected tests and never asks,
/// so it runs unguarded — the full runs are the ones that hung.
final class MainQueueWatchdogTests: XCTestCase {
    override class var defaultTestSuite: XCTestSuite {
        MainQueueWatchdog.startOnce()
        return super.defaultTestSuite
    }

    func testWatchdogIsRunning() throws {
        guard MainQueueWatchdog.isRunning else {
            throw XCTSkip("filtered run: XCTest never asked for the default suite")
        }
    }
}
