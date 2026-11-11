import XCTest

// Waiting primitives for async tests. Every wait here is bounded: when the
// thing a test waits for never happens, the test fails by name within
// seconds instead of hanging the whole `swift test` run.
//
// None of them use XCTest expectations. `await fulfillment(of:timeout:)`
// inside a @MainActor async test waits through XCTWaiter while XCTest's own
// XCTWaiter is already spinning the main run loop for the async test itself.
// In full-suite runs (after earlier suites had driven the real
// terminal-visibility probe) that combination repeatedly left the main queue
// undrained: main-actor jobs sat for ~2 s or forever, and XCTest logged
// "Run loop nesting count is negative (-1)". A test that only asserted a
// request stays pending could hang itself and the tests after it.

/// Upper bound for waits that normally finish in microseconds. Generous on
/// purpose: a loaded CI machine can deschedule the test process for seconds.
let asyncTestTimeout: TimeInterval = 5

/// Polls `condition` in the caller's isolation until it holds. Records a
/// failure and returns `false` once `timeout` passes.
@discardableResult
func waitUntil(
    timeout: TimeInterval = asyncTestTimeout,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail(timeoutDescription("Condition still false after \(timeout)s.", message()), file: file, line: line)
            return false
        }
        // A yield lets already-enqueued work run first; the short sleep keeps
        // a condition that needs another thread from busy-spinning the actor.
        await Task.yield()
        if condition() { break }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

/// Starts a hook request the way `HookServer` does — a task suspended on a
/// continuation that `handler` takes ownership of — and returns once
/// `handler` has actually run, so the request is queued (or already
/// answered) before the test looks at the state.
///
/// Replaces "create the task, `await Task.yield()` once, assume it ran":
/// whether one yield is enough depends on how the concurrency runtime
/// schedules the new task relative to the caller, which is not a contract.
@MainActor
func startHookRequest<T: Sendable>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: @escaping @MainActor (CheckedContinuation<T, Never>) -> Void
) async -> Task<T, Never> {
    let reached = HandlerReached()
    let task = Task { @MainActor in
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            handler(continuation)
            reached.value = true
        }
    }
    await waitUntil("the request task never reached its handler", file: file, line: line) {
        reached.value
    }
    return task
}

/// The value of a task that resolves a hook request, or — if nothing
/// resumes its continuation within `timeout` — a recorded failure that ends
/// the test. Awaiting `task.value` directly would hang the run forever.
func awaitValue<T: Sendable>(
    of task: Task<T, Never>,
    timeout: TimeInterval = asyncTestTimeout,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let result: T? = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = ResumeOnce(continuation)
        let timer = Task.detached {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return  // cancelled because the value arrived first
            }
            gate.resume(returning: nil)
        }
        // Left suspended if the task never finishes; it holds no thread.
        Task.detached {
            let value = await task.value
            gate.resume(returning: value)
            timer.cancel()
        }
    }
    return try XCTUnwrap(
        result,
        timeoutDescription("Task did not finish within \(timeout)s — nothing resumed its continuation.", message()),
        file: file,
        line: line
    )
}

/// Asserts `task` is still unresolved after `duration` — a request that must
/// keep its CLI blocked (dismissed, or waiting behind another decision).
func assertStillPending<T: Sendable>(
    _ task: Task<T, Never>,
    for duration: TimeInterval = 0.05,
    _ message: @autoclosure () -> String = "task should stay pending",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let resolved = ResolvedFlag()
    // Left suspended until the test resolves `task` later; it holds no thread.
    Task.detached {
        _ = await task.value
        resolved.set()
    }
    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    XCTAssertFalse(resolved.isSet, message(), file: file, line: line)
}

private func timeoutDescription(_ what: String, _ context: String) -> String {
    context.isEmpty ? what : "\(what) \(context)"
}

@MainActor
private final class HandlerReached {
    var value = false
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

private final class ResolvedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
