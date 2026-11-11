import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class SessionLifecycleTests: XCTestCase {
    private func session(status: AgentStatus) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.source = "codex"
        value.status = status
        value.cwd = "/tmp/project"
        value.lastActivity = Date()
        return value
    }

    func testHideAndUnhideKeepSessionTracked() {
        let state = AppState()
        state.sessions["s1"] = session(status: .idle)

        state.hideSession("s1")
        XCTAssertTrue(state.hiddenSessionIds.contains("s1"))
        XCTAssertNotNil(state.sessions["s1"])

        state.unhideSession("s1")
        XCTAssertFalse(state.hiddenSessionIds.contains("s1"))
        XCTAssertNotNil(state.sessions["s1"])
    }

    func testClearCompletedSessionsDoesNotRemoveActiveOrWaiting() {
        let state = AppState()
        state.sessions["idle"] = session(status: .idle)
        state.sessions["running"] = session(status: .running)
        state.sessions["approval"] = session(status: .waitingApproval)
        state.sessions["question"] = session(status: .waitingQuestion)

        let count = state.clearCompletedSessions()

        XCTAssertEqual(count, 1)
        XCTAssertNil(state.sessions["idle"])
        XCTAssertNotNil(state.sessions["running"])
        XCTAssertNotNil(state.sessions["approval"])
        XCTAssertNotNil(state.sessions["question"])
    }

    func testRemovingSessionAlsoDropsItsHiddenMarker() {
        let state = AppState()
        state.sessions["s1"] = session(status: .idle)
        state.hideSession("s1")

        state.removeSession("s1")

        XCTAssertFalse(state.hiddenSessionIds.contains("s1"))
    }
}
