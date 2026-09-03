import AppKit
import XCTest
@testable import MacDictate

@MainActor
private final class StubAudioRecorder: AudioRecording {
    var currentInputDeviceName = "Mock Microphone"
    var availableInputDevices: [AudioInputDevice] = []
    var inputLevel: Float = 0
    var isReadyForRecording = true
    var onInterruption: ((String) -> Void)?
    var onInputDeviceFallback: ((AudioInputSelection) -> Void)?
    var onInputDeviceReconnection: ((AudioInputSelection) -> Void)?

    func selectInputDevice(_ selection: AudioInputSelection) throws {}
    func prepare() async throws {}
    func start() throws {}
    func stop() throws -> RecordedAudio {
        RecordedAudio(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stub.wav"),
            duration: 1,
            peakAmplitude: 0.5,
            rmsAmplitude: 0.1
        )
    }
    func cancel() {}
}

@MainActor
final class HUDControllerTests: XCTestCase {
    private var settings: SettingsStore!
    private var stateMachine: DictationStateMachine!
    private var recorder: StubAudioRecorder!
    private var hud: HUDController!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "HUDControllerTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.showHUD = true
        stateMachine = DictationStateMachine()
        recorder = StubAudioRecorder()
        hud = HUDController(
            stateMachine: stateMachine,
            settings: settings,
            audioRecorder: recorder
        )
    }

    override func tearDown() async throws {
        hud = nil
        stateMachine = nil
        recorder = nil
        settings = nil
    }

    /// SwiftUI now owns the panel size, so the 190/520 width bounds live in `HUDView`'s frame
    /// rather than in a manual `setContentSize`. A device name far wider than the ceiling must
    /// still land inside those bounds.
    func testOverlongDeviceNameSettlesWithinWidthBounds() throws {
        recorder.currentInputDeviceName = String(repeating: "Very Long Microphone Name ", count: 12)

        try stateMachine.transition(to: .preparing)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try stateMachine.transition(to: .recording(startedAt: Date()))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let width = hud.panel.frame.width
        XCTAssertGreaterThanOrEqual(width, 190)
        XCTAssertLessThanOrEqual(width, 520)
    }
}
