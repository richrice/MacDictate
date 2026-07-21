import AppKit
import XCTest
@testable import MacDictate

@MainActor
private final class MockAudioRecorder: AudioRecording {
    var currentInputDeviceName = "Mock Microphone"
    var availableInputDeviceNames: [String] = []
    var onInterruption: ((String) -> Void)?

    var peakAmplitude: Float = 0.5
    var duration: TimeInterval = 1.0
    private(set) var cancelCount = 0

    func prepare() async throws {}
    func start() throws {}
    func stop() throws -> RecordedAudio {
        RecordedAudio(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDictate-mock-\(UUID().uuidString).wav"),
            duration: duration,
            peakAmplitude: peakAmplitude
        )
    }

    func cancel() { cancelCount += 1 }
}

private final class MockTranscriptionService: TranscriptionService, @unchecked Sendable {
    enum Behavior: Sendable {
        case success(String)
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

    func insert(_ text: String, target: TargetApplication) async throws -> TextInsertionOutcome {
        inserted.append(text)
        return .accessibility
    }

    func copy(_ text: String) { copied.append(text) }
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
    private var stateMachine: DictationStateMachine!
    private var recorder: MockAudioRecorder!
    private var transcription: MockTranscriptionService!
    private var insertion: MockInsertionService!
    private var credentials: InMemoryCredentialStore!
    private var cleaner: MockFileCleaner!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "CoordinatorWorkflowTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.playSounds = false
        settings.showHUD = false

        stateMachine = DictationStateMachine()
        recorder = MockAudioRecorder()
        transcription = MockTranscriptionService()
        insertion = MockInsertionService()
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
    }
}
