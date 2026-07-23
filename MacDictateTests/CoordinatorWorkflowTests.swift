import AppKit
import XCTest
@testable import MacDictate

@MainActor
private final class MockAudioRecorder: AudioRecording {
    var currentInputDeviceName = "Mock Microphone"
    var availableInputDevices: [AudioInputDevice] = []
    var inputLevel: Float = 0
    var isReadyForRecording = true
    var onInterruption: ((String) -> Void)?
    var onInputDeviceFallback: ((AudioInputSelection) -> Void)?
    private(set) var selectedInputDevice: AudioInputSelection = .systemDefault

    var peakAmplitude: Float = 0.5
    var rmsAmplitude: Float = 0.1
    var duration: TimeInterval = 1.0
    var onPrepare: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var suspendNextPrepare = false
    private var suspendedPrepareContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0

    func selectInputDevice(_ selection: AudioInputSelection) throws {
        selectedInputDevice = selection
    }

    func prepare() async throws {
        onPrepare?()
        if suspendNextPrepare {
            suspendNextPrepare = false
            await withCheckedContinuation { continuation in
                suspendedPrepareContinuation = continuation
            }
        }
        try Task.checkCancellation()
    }

    var hasSuspendedPrepare: Bool {
        suspendedPrepareContinuation != nil
    }

    func resumeSuspendedPrepare() {
        let continuation = suspendedPrepareContinuation
        suspendedPrepareContinuation = nil
        continuation?.resume()
    }
    func start() throws {}
    func stop() throws -> RecordedAudio {
        onStop?()
        return RecordedAudio(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDictate-mock-\(UUID().uuidString).wav"),
            duration: duration,
            peakAmplitude: peakAmplitude,
            rmsAmplitude: rmsAmplitude
        )
    }

    func cancel() {
        onCancel?()
        cancelCount += 1
    }
}

private final class MockTranscriptionService: TranscriptionService, @unchecked Sendable {
    enum Behavior: Sendable {
        case success(String)
        case delayedSuccess(String)
        case failure(TranscriptionError)
        /// Sleeps until the surrounding task is cancelled, like an in-flight upload.
        case hangUntilCancelled
    }

    private let lock = NSLock()
    private var _behavior: Behavior = .success("hello world")
    private var _calls = 0

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func transcribe(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> String {
        lock.withLock { _calls += 1 }
        switch behavior {
        case let .success(text):
            return text
        case let .delayedSuccess(text):
            try await Task.sleep(for: .milliseconds(500))
            return text
        case let .failure(error):
            throw error
        case .hangUntilCancelled:
            try await Task.sleep(for: .seconds(30))
            throw TranscriptionError.malformedResponse
        }
    }
}

@MainActor
private final class MockInsertionService: TextInsertionService {
    private(set) var inserted: [String] = []
    private(set) var copied: [String] = []
    var outcome: TextInsertionOutcome = .accessibility

    func insert(_ text: String, target: TargetApplication) async throws -> TextInsertionOutcome {
        inserted.append(text)
        return outcome
    }

    func copy(_ text: String) { copied.append(text) }
}

@MainActor
private final class MockSystemAudioOutputController: SystemAudioOutputControlling {
    private(set) var muteCount: Int = 0
    private(set) var prepareCount: Int = 0
    private(set) var restoreCount: Int = 0
    var onPrepare: (() -> Void)?
    var onRestore: (() -> Void)?
    private var currentlyMuted = false
    private var activeWorkflowID: UUID?

    var isCurrentlyMuted: Bool { currentlyMuted }

    func prepareForDictation(workflowID: UUID) {
        activeWorkflowID = workflowID
        onPrepare?()
        prepareCount += 1
    }

    func muteForDictation(workflowID: UUID) {
        guard activeWorkflowID == workflowID else { return }
        muteCount += 1
        currentlyMuted = true
    }

    func restoreAfterDictation(workflowID: UUID) {
        guard activeWorkflowID == workflowID else { return }
        activeWorkflowID = nil
        onRestore?()
        restoreCount += 1
        currentlyMuted = false
    }
}

private final class MockFileCleaner: TemporaryFileCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var _deleted: [URL] = []

    func delete(_ url: URL) { lock.withLock { _deleted.append(url) } }
    var deleted: [URL] { lock.withLock { _deleted } }
}

@MainActor
final class CoordinatorWorkflowTests: XCTestCase {
    private var coordinator: AppCoordinator!
    private var settings: SettingsStore!
    private var stateMachine: DictationStateMachine!
    private var recorder: MockAudioRecorder!
    private var transcription: MockTranscriptionService!
    private var insertion: MockInsertionService!
    private var audioOutputController: MockSystemAudioOutputController!
    private var credentials: InMemoryCredentialStore!
    private var cleaner: MockFileCleaner!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "CoordinatorWorkflowTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.playSounds = false
        settings.showHUD = false

        stateMachine = DictationStateMachine()
        recorder = MockAudioRecorder()
        transcription = MockTranscriptionService()
        insertion = MockInsertionService()
        audioOutputController = MockSystemAudioOutputController()
        credentials = InMemoryCredentialStore()
        try credentials.save("test-key")
        cleaner = MockFileCleaner()

        let microphonePermission = MicrophonePermissionManager()
        coordinator = AppCoordinator(
            settings: settings,
            stateMachine: stateMachine,
            hotkeyManager: GlobalHotkeyManager(),
            microphonePermission: microphonePermission,
            accessibilityPermission: AccessibilityPermissionManager(),
            launchAtLogin: LaunchAtLoginManager(),
            audioRecorder: recorder,
            transcriptionService: transcription,
            credentialStore: credentials,
            insertionService: insertion,
            audioOutputController: audioOutputController,
            fileCleaner: cleaner
        )
        // Deterministic target regardless of which app is frontmost during tests.
        coordinator.lastExternalTarget = TargetApplication(
            processIdentifier: 1,
            bundleIdentifier: "com.example.target",
            name: "Target"
        )
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private func holdThroughMinimumPress() async throws {
        coordinator.beginDictation()
        await waitFor("recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    func testHappyPathTranscribesAndInserts() async throws {
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should complete") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(stateMachine.state, .completed(message: "Text inserted"))
        XCTAssertEqual(insertion.inserted, ["hello world"])
        XCTAssertEqual(cleaner.deleted.count, 1, "The temporary recording must be deleted")
        XCTAssertNil(coordinator.lastErrorDetails)
        XCTAssertEqual(audioOutputController.prepareCount, 1)
        XCTAssertGreaterThanOrEqual(audioOutputController.muteCount, 1)
        XCTAssertFalse(audioOutputController.isCurrentlyMuted)
    }

    func testUnverifiedAutomaticInsertionIsNotReportedAsSuccessful() async throws {
        insertion.outcome = .automaticInsertionUnverified
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should complete") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(stateMachine.state, .completed(message: "Insertion unconfirmed"))
        XCTAssertEqual(insertion.inserted, ["hello world"])
    }

    func testDispatchedPasteUsesTruthfulCompletionMessage() async throws {
        insertion.outcome = .pasteDispatched
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should complete") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(stateMachine.state, .completed(message: "Paste sent"))
        XCTAssertEqual(insertion.inserted, ["hello world"])
    }

    func testCopySettingDoesNotOverwriteUnverifiedInsertionMessage() async throws {
        insertion.outcome = .automaticInsertionUnverified
        settings.copyToClipboard = true
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should complete") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(stateMachine.state, .completed(message: "Insertion unconfirmed"))
        XCTAssertEqual(insertion.copied, ["hello world"])
    }

    func testShortPressCancelsWithoutTranscribing() async throws {
        coordinator.beginDictation()
        await waitFor("recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }
        coordinator.finishDictation()

        XCTAssertEqual(stateMachine.state, .cancelled(message: nil))
        XCTAssertEqual(transcription.calls, 0)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(audioOutputController.muteCount, 1)
        XCTAssertFalse(audioOutputController.isCurrentlyMuted)
    }

    func testStopsInputBeforeRestoringOutputAfterDelivery() async throws {
        transcription.behavior = .delayedSuccess("hello world")
        try await holdThroughMinimumPress()
        var events: [String] = []
        audioOutputController.onRestore = { events.append("restore output") }
        recorder.onStop = { events.append("stop input") }

        coordinator.finishDictation()
        await waitFor("transcription should start") { self.stateMachine.state == .transcribing }
        XCTAssertEqual(events, ["stop input"])
        XCTAssertTrue(audioOutputController.isCurrentlyMuted)

        await waitFor("workflow should complete") { self.stateMachine.state.isTerminal }
        XCTAssertEqual(events, ["stop input", "restore output"])
        XCTAssertFalse(audioOutputController.isCurrentlyMuted)
    }

    func testCancelsInputBeforeRestoringOutput() async throws {
        coordinator.beginDictation()
        await waitFor("recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }
        var events: [String] = []
        audioOutputController.onRestore = { events.append("restore output") }
        recorder.onCancel = { events.append("cancel input") }

        coordinator.finishDictation()

        XCTAssertEqual(events, ["cancel input", "restore output"])
    }

    func testMuteIsReassertedWhileRecording() async throws {
        coordinator.beginDictation()
        await waitFor("recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }
        await waitFor("mute should be reasserted") {
            self.audioOutputController.muteCount >= 2
        }

        coordinator.cancelActive()

        XCTAssertFalse(audioOutputController.isCurrentlyMuted)
    }

    func testImmediateMuteIsRestoredWhenRecordingEndsQuickly() async throws {
        settings.playSounds = true
        coordinator.beginDictation()
        await waitFor("recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }
        coordinator.finishDictation()
        await waitFor("workflow should end") { self.stateMachine.state.isTerminal }

        XCTAssertGreaterThanOrEqual(audioOutputController.muteCount, 1)
        XCTAssertFalse(audioOutputController.isCurrentlyMuted)
    }

    func testCapturesAndMutesOutputBeforePreparingInput() async throws {
        var events: [String] = []
        audioOutputController.onPrepare = { events.append("capture output") }
        recorder.onPrepare = { events.append("prepare input") }

        coordinator.beginDictation()
        await waitFor("recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }

        XCTAssertEqual(events, ["capture output", "prepare input"])
        coordinator.cancelActive()
    }

    func testPressDuringTerminalCooldownStartsNewDictation() async throws {
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("first workflow should complete") { self.stateMachine.state.isTerminal }

        // Press again immediately, inside the post-completion cooldown, and hold
        // past the old reset window so a stale reset task would be caught
        // clobbering the captured target.
        coordinator.beginDictation()
        await waitFor("second recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }
        try await Task.sleep(for: .seconds(1.5))
        coordinator.finishDictation()
        await waitFor("second workflow should complete") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(stateMachine.state, .completed(message: "Text inserted"))
        XCTAssertEqual(insertion.inserted.count, 2)
    }

    func testCancelledPreparationCannotCancelNewDictation() async throws {
        recorder.suspendNextPrepare = true
        coordinator.beginDictation()
        await waitFor("first preparation should suspend") {
            self.recorder.hasSuspendedPrepare
        }

        coordinator.finishDictation()
        XCTAssertEqual(stateMachine.state, .cancelled(message: nil))
        XCTAssertFalse(audioOutputController.isCurrentlyMuted)

        coordinator.beginDictation()
        await waitFor("second recording should start") {
            if case .recording = self.stateMachine.state { true } else { false }
        }
        XCTAssertTrue(audioOutputController.isCurrentlyMuted)

        // The cancelled first preparation finishes late. Its cancellation
        // handler must not cancel or restore audio for the second dictation.
        recorder.resumeSuspendedPrepare()
        try await Task.sleep(for: .milliseconds(100))

        if case .recording = stateMachine.state {
            // Expected.
        } else {
            XCTFail("Late cleanup replaced the active dictation: \(stateMachine.state)")
        }
        XCTAssertTrue(audioOutputController.isCurrentlyMuted)

        coordinator.cancelActive()
        XCTAssertFalse(audioOutputController.isCurrentlyMuted)
    }

    func testPressDuringInputTeardownDoesNotStartAnotherWorkflow() async throws {
        recorder.isReadyForRecording = false

        coordinator.beginDictation()

        XCTAssertEqual(stateMachine.state, .idle)
        XCTAssertEqual(audioOutputController.prepareCount, 0)
        XCTAssertEqual(audioOutputController.muteCount, 0)

        recorder.isReadyForRecording = true
        coordinator.beginDictation()
        await waitFor("recording should start after input teardown") {
            if case .recording = self.stateMachine.state { true } else { false }
        }

        XCTAssertEqual(audioOutputController.prepareCount, 1)
        coordinator.cancelActive()
    }

    func testCancelDuringTranscriptionEndsCleanlyWithoutError() async throws {
        transcription.behavior = .hangUntilCancelled
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("transcription should start") { self.stateMachine.state == .transcribing }

        coordinator.cancelActive()
        // Give the cancelled workflow task time to run its catch path.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(stateMachine.state, .cancelled(message: nil))
        XCTAssertNil(coordinator.lastErrorDetails, "A user cancel must not be recorded as an error")
        XCTAssertEqual(cleaner.deleted.count, 1)
    }

    func testSilentRecordingIsBenignCancel() async throws {
        recorder.peakAmplitude = 0
        try await holdThroughMinimumPress()
        coordinator.finishDictation()

        XCTAssertEqual(stateMachine.state, .cancelled(message: "No speech detected"))
        XCTAssertEqual(transcription.calls, 0)
        XCTAssertEqual(cleaner.deleted.count, 1)
        XCTAssertNil(coordinator.lastErrorDetails)
    }

    func testEmptyTranscriptionIsBenignCancel() async throws {
        transcription.behavior = .failure(.emptyTranscription)
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should end") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(stateMachine.state, .cancelled(message: "No speech detected"))
        XCTAssertNil(coordinator.lastErrorDetails)
        XCTAssertEqual(cleaner.deleted.count, 1)
    }

    func testPromptEchoTranscriptionIsBenignCancel() async throws {
        // Silent-audio hallucination: the model returns the context prompt.
        transcription.behavior = .success("###\n\(SettingsStore.defaultPrompt)\n###")
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should end") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(stateMachine.state, .cancelled(message: "No speech detected"))
        XCTAssertEqual(insertion.inserted, [], "A prompt echo must never be inserted")
        XCTAssertNil(coordinator.lastErrorDetails)
    }

    func testQuietButAudibleRecordingWithClickIsRejected() async throws {
        // A key click gives a peak above the old gate, but overall energy is silence.
        recorder.peakAmplitude = 0.05
        recorder.rmsAmplitude = 0.0001
        try await holdThroughMinimumPress()
        coordinator.finishDictation()

        XCTAssertEqual(stateMachine.state, .cancelled(message: "No speech detected"))
        XCTAssertEqual(transcription.calls, 0)
    }

    func testMissingAPIKeyFails() async throws {
        try credentials.delete()
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should end") { self.stateMachine.state.isTerminal }

        guard case let .failed(message) = stateMachine.state else {
            XCTFail("Expected failure, got \(stateMachine.state)")
            return
        }
        XCTAssertEqual(message, TranscriptionError.missingAPIKey.localizedDescription)
        XCTAssertEqual(transcription.calls, 0)
        XCTAssertNotNil(coordinator.lastErrorDetails)
        XCTAssertFalse(audioOutputController.isCurrentlyMuted)
    }

    func testMuteDisabledSettingSkipsMuting() async throws {
        settings.muteSystemAudioDuringDictation = false
        try await holdThroughMinimumPress()
        coordinator.finishDictation()
        await waitFor("workflow should complete") { self.stateMachine.state.isTerminal }

        XCTAssertEqual(audioOutputController.muteCount, 0)
        XCTAssertEqual(audioOutputController.prepareCount, 0)
    }
}
