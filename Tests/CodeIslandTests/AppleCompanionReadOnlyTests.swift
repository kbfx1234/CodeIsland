import XCTest
import CodeIslandCore
@testable import CodeIsland

/// iPhone Buddy connects without pairing, so any nearby device running it can
/// send commands: until it pairs, the Mac takes none that answer for the user.
@MainActor
final class AppleCompanionReadOnlyTests: XCTestCase {
    private var publisher: AppleCompanionPublisher { .shared }
    private var savedControl: ((BuddyControlCommand, String?) -> Void)?
    private var savedAnswer: ((String, String?) -> Void)?
    private var savedFocus: ((MascotID) -> Void)?

    override func setUp() async throws {
        savedControl = publisher.onControlCommand
        savedAnswer = publisher.onQuestionAnswer
        savedFocus = publisher.onFocusRequest
    }

    override func tearDown() async throws {
        publisher.onControlCommand = savedControl
        publisher.onQuestionAnswer = savedAnswer
        publisher.onFocusRequest = savedFocus
    }

    func testCommandsThatAnswerForTheUserAreIgnored() {
        var decided: [String] = []
        publisher.onControlCommand = { command, _ in decided.append("\(command)") }
        publisher.onQuestionAnswer = { answer, _ in decided.append("answer \(answer)") }

        for type in [AppleCompanionCommandType.approveCurrentPermission, .denyCurrentPermission, .skipCurrentQuestion] {
            publisher.handleCommand(AppleCompanionCommandPayload(type: type, sessionId: "s1"))
        }
        publisher.handleCommand(AppleCompanionCommandPayload(type: .answerQuestion, sessionId: "s1", answer: "Yes"))

        XCTAssertEqual(decided, [], "a nearby device answered a request for the user")
    }

    func testFocusStillWorks() {
        var focused: [MascotID] = []
        publisher.onFocusRequest = { focused.append($0) }
        publisher.handleCommand(AppleCompanionCommandPayload(type: .focus, source: "codex"))
        XCTAssertEqual(focused.count, 1)
    }
}
