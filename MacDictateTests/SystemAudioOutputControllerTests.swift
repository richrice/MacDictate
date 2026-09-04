import CoreAudio
import XCTest
@testable import MacDictate

@MainActor
private final class MockProcessAudioTapAccess: ProcessAudioTapAccess {
    var nextTapID: AudioObjectID = 42
    var creationError: Error?
    var destructionStatus: OSStatus = noErr
    private(set) var excludedProcessIDs: [pid_t] = []
    private(set) var destroyedTapIDs: [AudioObjectID] = []

    func createGlobalMuteTap(excludingProcessID: pid_t) throws -> AudioObjectID {
        if let creationError { throw creationError }
        excludedProcessIDs.append(excludingProcessID)
        return nextTapID
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        destroyedTapIDs.append(tapID)
        return destructionStatus
    }
}

@MainActor
final class SystemAudioOutputControllerTests: XCTestCase {
    func testSilenceCreatesOneTapAndRestoreDestroysIt() throws {
        let access = MockProcessAudioTapAccess()
        let controller = SystemAudioOutputController(tapAccess: access)
        let workflowID = UUID()

        try controller.silenceForDictation(workflowID: workflowID)
        try controller.silenceForDictation(workflowID: workflowID)

        XCTAssertEqual(access.excludedProcessIDs, [ProcessInfo.processInfo.processIdentifier])
        XCTAssertEqual(access.destroyedTapIDs, [])

        controller.restoreAfterDictation(workflowID: workflowID)
        XCTAssertEqual(access.destroyedTapIDs, [42])

        controller.restoreAfterDictation(workflowID: workflowID)
        XCTAssertEqual(access.destroyedTapIDs, [42])
    }

    func testNewWorkflowTakesOwnershipWithoutRecreatingTap() throws {
        let access = MockProcessAudioTapAccess()
        let controller = SystemAudioOutputController(tapAccess: access)
        let firstWorkflowID = UUID()
        let secondWorkflowID = UUID()

        try controller.silenceForDictation(workflowID: firstWorkflowID)
        try controller.silenceForDictation(workflowID: secondWorkflowID)

        XCTAssertEqual(access.excludedProcessIDs.count, 1)
        controller.restoreAfterDictation(workflowID: firstWorkflowID)
        XCTAssertEqual(access.destroyedTapIDs, [])

        controller.restoreAfterDictation(workflowID: secondWorkflowID)
        XCTAssertEqual(access.destroyedTapIDs, [42])
    }

    func testCreationFailureIsPropagatedAndCanBeRetried() throws {
        let access = MockProcessAudioTapAccess()
        let controller = SystemAudioOutputController(tapAccess: access)
        let workflowID = UUID()
        access.creationError = SystemAudioSilencingError.tapCreationFailed(-1)

        XCTAssertThrowsError(try controller.silenceForDictation(workflowID: workflowID)) { error in
            XCTAssertEqual(error as? SystemAudioSilencingError, .tapCreationFailed(-1))
        }

        access.creationError = nil
        try controller.silenceForDictation(workflowID: workflowID)
        XCTAssertEqual(access.excludedProcessIDs.count, 1)
    }

    func testFailedDestructionRemainsTrackedForTerminationRetry() throws {
        let access = MockProcessAudioTapAccess()
        let controller = SystemAudioOutputController(tapAccess: access)
        let workflowID = UUID()

        try controller.silenceForDictation(workflowID: workflowID)
        access.destructionStatus = -1
        controller.restoreAfterDictation(workflowID: workflowID)
        XCTAssertEqual(access.destroyedTapIDs, [42])

        access.destructionStatus = noErr
        controller.restoreImmediately()
        XCTAssertEqual(access.destroyedTapIDs, [42, 42])

        controller.restoreImmediately()
        XCTAssertEqual(access.destroyedTapIDs, [42, 42])
    }

    func testImmediateRestoreDestroysActiveTap() throws {
        let access = MockProcessAudioTapAccess()
        let controller = SystemAudioOutputController(tapAccess: access)

        try controller.silenceForDictation(workflowID: UUID())
        controller.restoreImmediately()

        XCTAssertEqual(access.destroyedTapIDs, [42])
    }
}
