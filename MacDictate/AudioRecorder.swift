@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct RecordedAudio: Sendable, Equatable {
    let fileURL: URL
    let duration: TimeInterval
    let peakAmplitude: Float
    let rmsAmplitude: Float

    // Peak alone is a weak gate: a single breath or key click exceeds it.
    // RMS catches recordings whose overall energy is far below speech.
    var isEffectivelySilent: Bool {
        peakAmplitude < 0.003 || rmsAmplitude < 0.001 || duration <= 0
    }
}

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }
    var selection: AudioInputSelection { .device(uid: uid, name: name) }
}

enum AudioInputSelection: Codable, Hashable, Sendable {
    case systemDefault
    case device(uid: String, name: String)

    var displayName: String {
        switch self {
        case .systemDefault: "System Default"
        case let .device(_, name): name
        }
    }

    var uid: String? {
        switch self {
        case .systemDefault: nil
        case let .device(uid, _): uid
        }
    }

    var requiresExplicitDeviceBinding: Bool {
        if case .device = self { true } else { false }
    }
}

enum AudioTapBlockFactory {
    nonisolated static func make(
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in handler(buffer) }
    }
}

enum AudioRecorderError: LocalizedError, Equatable {
    case permissionDenied
    case noInputDevice
    case alreadyRecording
    case notRecording
    case inputDeviceUnavailable(String)
    case inputDeviceSelectionFailed(String, OSStatus)
    case cannotCreateFile(String)
    case engineFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is required to record dictation."
        case .noInputDevice: "No microphone input device is available."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no active recording."
        case let .inputDeviceUnavailable(name): "The selected microphone “\(name)” is not available."
        case let .inputDeviceSelectionFailed(name, status): "Could not select the microphone “\(name)” (Core Audio error \(status))."
        case let .cannotCreateFile(detail): "Could not create a temporary WAV file. \(detail)"
        case let .engineFailed(detail): "The microphone could not start. \(detail)"
        case let .conversionFailed(detail): "Audio conversion failed. \(detail)"
        }
    }
}

@MainActor
protocol AudioRecording: AnyObject {
    var currentInputDeviceName: String { get }
    var availableInputDevices: [AudioInputDevice] { get }
    var inputLevel: Float { get }
    var onInterruption: ((String) -> Void)? { get set }
    var onInputDeviceFallback: ((AudioInputSelection) -> Void)? { get set }
    func selectInputDevice(_ selection: AudioInputSelection) throws
    func prepare() async throws
    func start() throws
    func stop() throws -> RecordedAudio
    func cancel()
}

final class LockedAudioWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter
    private var file: AVAudioFile?
    private let outputFormat: AVAudioFormat
    private(set) var frameCount: AVAudioFramePosition = 0
    private(set) var peakAmplitude: Float = 0
    private var sumOfSquares = 0.0
    private var levelSampleCount = 0
    private var latestPeakAmplitude: Float = 0
    private var firstError: Error?

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.conversionFailed("The microphone format is unsupported.")
        }
        self.outputFormat = outputFormat
        self.converter = converter
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw AudioRecorderError.cannotCreateFile(error.localizedDescription)
        }
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard firstError == nil, let file else { return }

        // The input format can change mid-recording (device switch, sample-rate
        // renegotiation); rebuild the converter so the recording continues.
        if input.format != converter.inputFormat {
            guard let newConverter = AVAudioConverter(from: input.format, to: outputFormat) else {
                firstError = AudioRecorderError.conversionFailed("The microphone changed to an unsupported format.")
                return
            }
            converter = newConverter
        }

        updatePeak(from: input)
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = max(AVAudioFrameCount(Double(input.frameLength) * ratio) + 64, 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        let provider = OneShotAudioBufferProvider(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            provider.next(statusPointer: statusPointer)
        }

        if let conversionError {
            firstError = conversionError
            return
        }
        guard status != .error, output.frameLength > 0 else { return }
        do {
            try file.write(from: output)
            frameCount += AVAudioFramePosition(output.frameLength)
        } catch {
            firstError = error
        }
    }

    func finish() throws -> (frames: AVAudioFramePosition, peak: Float, rms: Float) {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        if let firstError {
            throw AudioRecorderError.conversionFailed(firstError.localizedDescription)
        }
        let rms = levelSampleCount > 0 ? Float((sumOfSquares / Double(levelSampleCount)).squareRoot()) : 0
        return (frameCount, peakAmplitude, rms)
    }

    var livePeakAmplitude: Float {
        lock.lock()
        defer { lock.unlock() }
        return latestPeakAmplitude
    }

    private func updatePeak(from buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var bufferPeak: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for index in 0..<frameLength {
                let sample = samples[index]
                let magnitude = abs(sample)
                bufferPeak = max(bufferPeak, magnitude)
                peakAmplitude = max(peakAmplitude, magnitude)
                sumOfSquares += Double(sample * sample)
            }
        }
        latestPeakAmplitude = bufferPeak
        levelSampleCount += channelCount * frameLength
    }
}

private final class OneShotAudioBufferProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(statusPointer: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else {
            statusPointer.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        statusPointer.pointee = .haveData
        return buffer
    }
}

enum AudioLevelScale {
    static func normalized(peakAmplitude: Float) -> Float {
        guard peakAmplitude > 0 else { return 0 }
        let decibels = 20 * log10(peakAmplitude)
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

private enum CoreAudioInputDevices {
    static var available: [AudioInputDevice] {
        allDeviceIDs()
            .filter(hasInputStreams)
            .compactMap { deviceID in
                guard let uid = stringProperty(
                    deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                ), let name = stringProperty(
                    deviceID,
                    selector: kAudioObjectPropertyName
                ) else {
                    return nil
                }
                return AudioInputDevice(uid: uid, name: name)
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static var defaultDeviceID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first {
            stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    static func name(for deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        return status == noErr ? deviceIDs : []
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr && size >= MemoryLayout<AudioStreamID>.size
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

@MainActor
final class AudioRecorder: AudioRecording {
    private let permissionManager: MicrophonePermissionProviding
    private var inputSelection: AudioInputSelection
    private var fallbackInputSelection: AudioInputSelection?
    private var engine: AVAudioEngine?
    private var activeInputDeviceID: AudioDeviceID?
    private var writer: LockedAudioWriter?
    private var recordingURL: URL?
    private var configurationObserver: NSObjectProtocol?

    var onInterruption: ((String) -> Void)?
    var onInputDeviceFallback: ((AudioInputSelection) -> Void)?

    var currentInputDeviceName: String {
        if let activeInputDeviceID {
            return CoreAudioInputDevices.name(for: activeInputDeviceID) ?? inputSelection.displayName
        }
        switch inputSelection {
        case .systemDefault:
            return CoreAudioInputDevices.defaultDeviceID
                .flatMap(CoreAudioInputDevices.name(for:)) ?? "No input device"
        case let .device(_, name):
            return name
        }
    }

    var availableInputDevices: [AudioInputDevice] {
        CoreAudioInputDevices.available
    }

    var inputLevel: Float {
        AudioLevelScale.normalized(peakAmplitude: writer?.livePeakAmplitude ?? 0)
    }

    init(
        permissionManager: MicrophonePermissionProviding,
        inputSelection: AudioInputSelection = .systemDefault,
        fallbackInputSelection: AudioInputSelection? = nil
    ) {
        self.permissionManager = permissionManager
        self.inputSelection = inputSelection
        self.fallbackInputSelection = fallbackInputSelection
    }

    func selectInputDevice(_ selection: AudioInputSelection) throws {
        guard writer == nil else { throw AudioRecorderError.alreadyRecording }
        _ = try resolveInputDeviceID(for: selection)
        if selection != inputSelection {
            fallbackInputSelection = inputSelection
            inputSelection = selection
        }
    }

    /// AVAudioEngine stops itself when the input configuration changes, and the
    /// notification often fires benignly as recording starts (Bluetooth
    /// profile switches, sample-rate renegotiation). Re-tap the input with its
    /// current format and restart; only report an interruption if that fails.
    private func recoverFromConfigurationChange() {
        guard let engine, let audioWriter = writer else { return }
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        do {
            try applyInputSelectionWithFallback()
        } catch {
            onInterruption?(error.localizedDescription)
            return
        }
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onInterruption?("The microphone configuration changed during recording.")
            return
        }
        let tapBlock = AudioTapBlockFactory.make { [audioWriter] buffer in
            audioWriter.append(buffer)
        }
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format, block: tapBlock)
        engine.prepare()
        do {
            try engine.start()
            AppLogger.audio.info("Recovered from an input configuration change during recording")
        } catch {
            inputNode.removeTap(onBus: 0)
            onInterruption?("The microphone configuration changed during recording.")
        }
    }

    func prepare() async throws {
        guard await permissionManager.request() else { throw AudioRecorderError.permissionDenied }
        try Task.checkCancellation()

        releaseInputEngine()
        let engine = AVAudioEngine()
        self.engine = engine
        observeConfigurationChanges(for: engine)
        do {
            try applyInputSelectionWithFallback()
            let format = engine.inputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioRecorderError.noInputDevice
            }
        } catch {
            releaseInputEngine()
            throw error
        }
    }

    func start() throws {
        guard writer == nil else { throw AudioRecorderError.alreadyRecording }
        guard let engine else {
            throw AudioRecorderError.engineFailed("The microphone was not prepared.")
        }
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDictate-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let audioWriter = try LockedAudioWriter(url: url, inputFormat: inputFormat)
        writer = audioWriter
        recordingURL = url

        let tapBlock = AudioTapBlockFactory.make { [audioWriter] buffer in
            audioWriter.append(buffer)
        }
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat, block: tapBlock)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            writer = nil
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
            releaseInputEngine()
            throw AudioRecorderError.engineFailed(error.localizedDescription)
        }
    }

    func stop() throws -> RecordedAudio {
        guard let engine, let writer, let url = recordingURL else {
            throw AudioRecorderError.notRecording
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.writer = nil
        recordingURL = nil
        releaseInputEngine()
        do {
            let result = try writer.finish()
            return RecordedAudio(
                fileURL: url,
                duration: Double(result.frames) / 16_000,
                peakAmplitude: result.peak,
                rmsAmplitude: result.rms
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func cancel() {
        if writer != nil, let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        writer = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        releaseInputEngine()
    }

    private func applyInputSelectionWithFallback() throws {
        do {
            try applyInputSelection(inputSelection)
        } catch let primaryError as AudioRecorderError {
            let canFallback: Bool
            switch primaryError {
            case .noInputDevice, .inputDeviceUnavailable, .inputDeviceSelectionFailed:
                canFallback = true
            default:
                canFallback = false
            }
            guard canFallback, let fallbackInputSelection,
                  fallbackInputSelection != inputSelection else {
                throw primaryError
            }

            do {
                try applyInputSelection(fallbackInputSelection)
            } catch {
                throw primaryError
            }

            let unavailableSelection = inputSelection
            inputSelection = fallbackInputSelection
            self.fallbackInputSelection = unavailableSelection
            AppLogger.audio.info(
                "Input device disconnected; fell back to \(self.currentInputDeviceName, privacy: .public)"
            )
            onInputDeviceFallback?(inputSelection)
        }
    }

    private func applyInputSelection(_ selection: AudioInputSelection) throws {
        let deviceID = try resolveInputDeviceID(for: selection)
        activeInputDeviceID = deviceID

        // AVAudioEngine follows macOS's default-device aggregate automatically.
        // Forcing its audio unit back to the physical default device fights that
        // aggregate during Bluetooth profile changes and repeatedly stops input.
        guard selection.requiresExplicitDeviceBinding else {
            AppLogger.audio.info("Using system default input: \(self.currentInputDeviceName, privacy: .public)")
            return
        }

        guard let engine else {
            throw AudioRecorderError.engineFailed("The microphone was not prepared.")
        }
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioRecorderError.engineFailed("The input audio unit is unavailable.")
        }

        engine.stop()
        engine.reset()
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.inputDeviceSelectionFailed(
                selection.displayName,
                status
            )
        }
        AppLogger.audio.info("Selected input device: \(self.currentInputDeviceName, privacy: .public)")
    }

    private func resolveInputDeviceID(
        for selection: AudioInputSelection
    ) throws -> AudioDeviceID {
        switch selection {
        case .systemDefault:
            guard let defaultDeviceID = CoreAudioInputDevices.defaultDeviceID else {
                throw AudioRecorderError.noInputDevice
            }
            return defaultDeviceID
        case let .device(uid, name):
            guard let selectedDeviceID = CoreAudioInputDevices.deviceID(forUID: uid),
                  CoreAudioInputDevices.available.contains(where: { $0.uid == uid }) else {
                throw AudioRecorderError.inputDeviceUnavailable(name)
            }
            return selectedDeviceID
        }
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverFromConfigurationChange()
            }
        }
    }

    private func releaseInputEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else {
            activeInputDeviceID = nil
            return
        }

        engine.stop()
        self.engine = nil
        activeInputDeviceID = nil

        // Bluetooth route changes can leave AVAudioIOUnit property callbacks
        // executing briefly after stop() returns. Keep the stopped engine alive
        // until those callbacks drain; deallocating it synchronously races the
        // callback and can crash inside AVAudioEngine dealloc.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            withExtendedLifetime(engine) {}
        }
    }
}

protocol TemporaryFileCleaning: Sendable {
    func delete(_ url: URL)
}

struct TemporaryFileCleaner: TemporaryFileCleaning {
    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
