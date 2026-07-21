import XCTest
@testable import MacDictate

@MainActor
final class StateMachineTests: XCTestCase {
    func testValidDictationStateTransitions() throws {
        let machine = DictationStateMachine()
        try machine.transition(to: .preparing)
        try machine.transition(to: .recording(startedAt: Date()))
        try machine.transition(to: .transcribing)
        try machine.transition(to: .inserting)
        try machine.transition(to: .completed(message: "Text inserted"))
        machine.resetAfterTerminalState()
        XCTAssertEqual(machine.state, .idle)
    }

    func testInvalidAndDuplicateTransitionsArePrevented() throws {
        let machine = DictationStateMachine()
        XCTAssertThrowsError(try machine.transition(to: .transcribing))
        try machine.transition(to: .preparing)
        XCTAssertThrowsError(try machine.transition(to: .preparing))
        XCTAssertEqual(machine.state, .preparing)
    }

    func testVeryShortRecordingIsCancelledByPolicy() {
        XCTAssertFalse(RecordingPolicy.shouldTranscribe(elapsed: 0.249))
        XCTAssertTrue(RecordingPolicy.shouldTranscribe(elapsed: 0.250))
    }
}

