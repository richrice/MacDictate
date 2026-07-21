@preconcurrency import AVFoundation
import Foundation

struct RecordedAudio: Sendable, Equatable {
    let fileURL: URL
    let duration: TimeInterval
    let peakAmplitude: Float

    var isEffectivelySilent: Bool {
        peakAmplitude < 0.003 || duration <= 0
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
    case cannotCreateFile(String)
    case engineFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is required to record dictation."
        case .noInputDevice: "No microphone input device is available."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no active recording."
        case let .cannotCreateFile(detail): "Could not create a temporary WAV file. \(detail)"
        case let .engineFailed(detail): "The microphone could not start. \(detail)"
        case let .conversionFailed(detail): "Audio conversion failed. \(detail)"
        }
    }
}

@MainActor
protocol AudioRecording: AnyObject {
    var currentInputDeviceName: String { get }
    var availableInputDeviceNames: [String] { get }
    var onInterruption: ((String) -> Void)? { get set }
    func prepare() async throws
    func start() throws
    func stop() throws -> RecordedAudio
    func cancel()
}

final class LockedAudioWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private var file: AVAudioFile?
    private let outputFormat: AVAudioFormat
    private(set) var frameCount: AVAudioFramePosition = 0
    private(set) var peakAmplitude: Float = 0
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

    func finish() throws -> (frames: AVAudioFramePosition, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        if let firstError {
            throw AudioRecorderError.conversionFailed(firstError.localizedDescription)
        }
        return (frameCount, peakAmplitude)
    }

    private func updatePeak(from buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for index in 0..<frameLength {
                peakAmplitude = max(peakAmplitude, abs(samples[index]))
            }
        }
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

@MainActor
final class AudioRecorder: AudioRecording {
    private let engine = AVAudioEngine()
    private let permissionManager: MicrophonePermissionProviding
    private var writer: LockedAudioWriter?
    private var recordingURL: URL?
    private var configurationObserver: NSObjectProtocol?

    var onInterruption: ((String) -> Void)?

    var currentInputDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "No input device"
    }

    var availableInputDeviceNames: [String] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map(\.localizedName).sorted()
    }

    init(permissionManager: MicrophonePermissionProviding) {
        self.permissionManager = permissionManager
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.writer != nil else { return }
                self.onInterruption?("The microphone configuration changed during recording.")
            }
        }
    }

    func prepare() async throws {
        guard await permissionManager.request() else { throw AudioRecorderError.permissionDenied }
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
    }

    func start() throws {
        guard writer == nil else { throw AudioRecorderError.alreadyRecording }
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
            throw AudioRecorderError.engineFailed(error.localizedDescription)
        }
    }

    func stop() throws -> RecordedAudio {
        guard let writer, let url = recordingURL else { throw AudioRecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.writer = nil
        recordingURL = nil
        do {
            let result = try writer.finish()
            return RecordedAudio(
                fileURL: url,
                duration: Double(result.frames) / 16_000,
                peakAmplitude: result.peak
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func cancel() {
        if writer != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        writer = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
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
