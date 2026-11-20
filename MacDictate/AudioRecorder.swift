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
}

enum AudioInputDeviceReconnector {
    static func replacement(
        for selection: AudioInputSelection,
        among availableDevices: [AudioInputDevice]
    ) -> AudioInputSelection? {
        guard case let .device(savedUID, savedName) = selection,
              !availableDevices.contains(where: { $0.uid == savedUID }) else {
            return nil
        }

        let matchingDevices = availableDevices.filter { $0.name == savedName }
        guard matchingDevices.count == 1 else { return nil }
        return matchingDevices[0].selection
    }
}

enum AudioInputFallbackPolicy {
    static func candidates(
        after preferred: AudioInputSelection,
        previous: AudioInputSelection?
    ) -> [AudioInputSelection] {
        var candidates: [AudioInputSelection] = []
        if let previous, previous != preferred {
            candidates.append(previous)
        }
        if preferred != .systemDefault, !candidates.contains(.systemDefault) {
            candidates.append(.systemDefault)
        }
        return candidates
    }
}

enum AudioQueueInputBlockFactory {
    /// The audio queue calls this block on its own dispatch queue. A block
    /// made in a main-actor method inherits that isolation and traps off the
    /// main thread, so this factory makes the block outside the main actor.
    nonisolated static func make(
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AudioQueueInputCallbackBlock {
        { queue, queueBuffer, _, _, _ in
            let byteCount = queueBuffer.pointee.mAudioDataByteSize
            let frameCount = byteCount / format.streamDescription.pointee.mBytesPerFrame
            if frameCount > 0,
               let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
               let samples = buffer.floatChannelData?[0] {
                buffer.frameLength = frameCount
                memcpy(samples, queueBuffer.pointee.mAudioData, Int(byteCount))
                handler(buffer)
            }
            // After a stop, the queue rejects the buffer. That is expected.
            AudioQueueEnqueueBuffer(queue, queueBuffer, 0, nil)
        }
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
        case .permissionDenied: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone, then try again."
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
    var isReadyForRecording: Bool { get }
    var onInterruption: ((String) -> Void)? { get set }
    var onInputDeviceFallback: ((AudioInputSelection) -> Void)? { get set }
    var onInputDeviceReconnection: ((AudioInputSelection) -> Void)? { get set }
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
            hasInputStreams($0)
                && stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    static func name(for deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    static func uid(for deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func nominalSampleRate(for deviceID: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
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

final class AudioQueueRunningListenerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStarted = false
    private var isExpectedStop = false
    private var didNotify = false
    private let onUnexpectedStop: @Sendable () -> Void

    init(onUnexpectedStop: @escaping @Sendable () -> Void) {
        self.onUnexpectedStop = onUnexpectedStop
    }

    func markStarted() {
        lock.withLock { hasStarted = true }
    }

    func markExpectedStop() {
        lock.withLock { isExpectedStop = true }
    }

    func notifyStopped() {
        let shouldFire = lock.withLock { () -> Bool in
            guard hasStarted, !isExpectedStop, !didNotify else { return false }
            didNotify = true
            return true
        }
        if shouldFire {
            onUnexpectedStop()
        }
    }
}

@MainActor
final class AudioDeviceListMonitor: ObservableObject {
    @Published private(set) var availableInputDevices: [AudioInputDevice] = []
    @Published private(set) var defaultInputDeviceName: String = "No input device"

    private nonisolated(unsafe) var devicesListener: AudioObjectPropertyListenerBlock?
    private nonisolated(unsafe) var defaultInputListener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        installListeners()
    }

    deinit {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let devicesListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                devicesListener
            )
        }
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                defaultInputListener
            )
        }
    }

    func refresh() {
        availableInputDevices = CoreAudioInputDevices.available
        defaultInputDeviceName = CoreAudioInputDevices.defaultDeviceID
            .flatMap(CoreAudioInputDevices.name(for:)) ?? "No input device"
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            block
        ) == noErr {
            devicesListener = block
        }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            block
        ) == noErr {
            defaultInputListener = block
        }
    }
}

@MainActor
final class AudioRecorder: AudioRecording {
    private static let teardownDrainDuration: Duration = .milliseconds(750)
    private static let queueBufferCount = 3
    private static let queueBufferDuration = 0.05

    private let permissionManager: MicrophonePermissionProviding
    private let callbackQueue = DispatchQueue(label: "MacDictate.AudioRecorder.input")
    private let teardownQueue = DispatchQueue(label: "MacDictate.AudioRecorder.teardown")
    private var inputSelection: AudioInputSelection
    private var fallbackInputSelection: AudioInputSelection?
    private var inputQueue: AudioQueueRef?
    private var runningListenerBox: AudioQueueRunningListenerBox?
    private var isRecording = false
    private var activeInputDeviceID: AudioDeviceID?
    private var activeInputDeviceName: String?
    private var writer: LockedAudioWriter?
    private var recordingURL: URL?
    private var pendingTeardownCount = 0
    private var restartAllowedAt: ContinuousClock.Instant?

    var onInterruption: ((String) -> Void)?
    var onInputDeviceFallback: ((AudioInputSelection) -> Void)?
    var onInputDeviceReconnection: ((AudioInputSelection) -> Void)?

    var currentInputDeviceName: String {
        if let activeInputDeviceName {
            return activeInputDeviceName
        }
        switch inputSelection {
        case .systemDefault:
            return CoreAudioInputDevices.defaultDeviceID
                .flatMap(CoreAudioInputDevices.name(for:)) ?? "No input device"
        case let .device(uid, name):
            return CoreAudioInputDevices.available.contains(where: { $0.uid == uid })
                ? name
                : "\(name) (Unavailable)"
        }
    }

    var availableInputDevices: [AudioInputDevice] {
        CoreAudioInputDevices.available
    }

    var inputLevel: Float {
        AudioLevelScale.normalized(peakAmplitude: writer?.livePeakAmplitude ?? 0)
    }

    var isReadyForRecording: Bool {
        guard pendingTeardownCount == 0 else { return false }
        guard let restartAllowedAt else { return true }
        return ContinuousClock().now >= restartAllowedAt
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

        if selection == inputSelection {
            reconnectSelectedInputIfAvailable()
            _ = try resolveInputDeviceID(for: inputSelection)
            return
        }

        _ = try resolveInputDeviceID(for: selection)
        fallbackInputSelection = inputSelection
        inputSelection = selection
    }

    /// Opens an input audio queue on the selected device. An audio queue
    /// records from the device it names. AVAudioEngine moved its input unit
    /// back to its default-device aggregate, so it recorded the default input
    /// (for example, a Bluetooth headset) and not the selected microphone.
    func prepare() async throws {
        guard await permissionManager.request() else { throw AudioRecorderError.permissionDenied }
        try Task.checkCancellation()

        releaseInput(flushBuffers: false)
        await waitForPendingTeardown()
        try Task.checkCancellation()
        try openInputWithFallback()
    }

    func start() throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }
        guard let inputQueue, let url = recordingURL else {
            throw AudioRecorderError.engineFailed("The microphone was not prepared.")
        }
        let status = AudioQueueStart(inputQueue, nil)
        guard status == noErr else {
            try? FileManager.default.removeItem(at: url)
            releaseInput(flushBuffers: false)
            throw AudioRecorderError.engineFailed("Core Audio error \(status).")
        }
        runningListenerBox?.markStarted()
        isRecording = true
    }

    func stop() throws -> RecordedAudio {
        guard isRecording, let writer, let url = recordingURL else {
            throw AudioRecorderError.notRecording
        }
        releaseInput(flushBuffers: true)
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
        let url = recordingURL
        releaseInput(flushBuffers: false)
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func openInputWithFallback() throws {
        reconnectSelectedInputIfAvailable()
        do {
            try openInput(inputSelection)
        } catch let primaryError as AudioRecorderError {
            let canFallback: Bool
            switch primaryError {
            case .noInputDevice, .inputDeviceUnavailable, .inputDeviceSelectionFailed:
                canFallback = true
            default:
                canFallback = false
            }
            guard canFallback else {
                throw primaryError
            }

            let unavailableSelection = inputSelection
            for fallback in AudioInputFallbackPolicy.candidates(
                after: unavailableSelection,
                previous: fallbackInputSelection
            ) {
                let resolvedFallback = AudioInputDeviceReconnector.replacement(
                    for: fallback,
                    among: CoreAudioInputDevices.available
                ) ?? fallback
                guard resolvedFallback != unavailableSelection else { continue }
                do {
                    try openInput(resolvedFallback)
                } catch is AudioRecorderError {
                    continue
                } catch {
                    throw error
                }

                inputSelection = resolvedFallback
                fallbackInputSelection = unavailableSelection
                AppLogger.audio.info(
                    "Input device could not be used; fell back to \(self.currentInputDeviceName, privacy: .public)"
                )
                onInputDeviceFallback?(inputSelection)
                return
            }
            throw primaryError
        }
    }

    private func reconnectSelectedInputIfAvailable() {
        guard let replacement = AudioInputDeviceReconnector.replacement(
            for: inputSelection,
            among: CoreAudioInputDevices.available
        ) else {
            return
        }

        let previousName = inputSelection.displayName
        inputSelection = replacement
        AppLogger.audio.info(
            "Reconnected \(previousName, privacy: .public) with its current Core Audio device ID"
        )
        onInputDeviceReconnection?(replacement)
    }

    private func openInput(_ selection: AudioInputSelection) throws {
        let deviceID = try resolveInputDeviceID(for: selection)
        guard let deviceUID = CoreAudioInputDevices.uid(for: deviceID) else {
            throw AudioRecorderError.inputDeviceUnavailable(selection.displayName)
        }
        guard let sampleRate = CoreAudioInputDevices.nominalSampleRate(for: deviceID),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioRecorderError.noInputDevice
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDictate-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let audioWriter = try LockedAudioWriter(url: url, inputFormat: format)
        let inputBlock = AudioQueueInputBlockFactory.make(format: format) { [audioWriter] buffer in
            audioWriter.append(buffer)
        }

        var queue: AudioQueueRef?
        var status = AudioQueueNewInputWithDispatchQueue(
            &queue,
            format.streamDescription,
            0,
            callbackQueue,
            inputBlock
        )
        guard status == noErr, let queue else {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.engineFailed("Core Audio error \(status).")
        }

        let deviceUIDRef = deviceUID as CFString
        var currentDevice = Unmanaged.passUnretained(deviceUIDRef)
        status = withExtendedLifetime(deviceUIDRef) {
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                &currentDevice,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            )
        }
        guard status == noErr else {
            AudioQueueDispose(queue, true)
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.inputDeviceSelectionFailed(selection.displayName, status)
        }

        let bytesPerBuffer = UInt32(sampleRate * Self.queueBufferDuration)
            * format.streamDescription.pointee.mBytesPerFrame
        for _ in 0..<Self.queueBufferCount {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(queue, bytesPerBuffer, &buffer)
            if status == noErr, let buffer {
                status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            }
            guard status == noErr else {
                AudioQueueDispose(queue, true)
                try? FileManager.default.removeItem(at: url)
                throw AudioRecorderError.engineFailed("Core Audio error \(status).")
            }
        }

        let listenerBox = AudioQueueRunningListenerBox { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                AppLogger.audio.error("The microphone input queue stopped unexpectedly")
                self.onInterruption?("The microphone stopped unexpectedly.")
            }
        }
        status = AudioQueueAddPropertyListener(
            queue,
            kAudioQueueProperty_IsRunning,
            Self.queueRunningListener,
            Unmanaged.passUnretained(listenerBox).toOpaque()
        )
        if status != noErr {
            AppLogger.audio.warning(
                "Could not observe microphone interruptions (Core Audio error \(status))"
            )
        }

        inputQueue = queue
        runningListenerBox = status == noErr ? listenerBox : nil
        writer = audioWriter
        recordingURL = url
        activeInputDeviceID = deviceID
        activeInputDeviceName = CoreAudioInputDevices.name(for: deviceID) ?? selection.displayName
        AppLogger.audio.info("Selected input device: \(self.currentInputDeviceName, privacy: .public)")
    }

    private nonisolated static let queueRunningListener: AudioQueuePropertyListenerProc = { userData, queue, propertyID in
        guard propertyID == kAudioQueueProperty_IsRunning, let userData else { return }
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &isRunning, &size) == noErr,
              isRunning == 0 else {
            return
        }
        let box = Unmanaged<AudioQueueRunningListenerBox>.fromOpaque(userData).takeUnretainedValue()
        box.notifyStopped()
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
            guard let selectedDeviceID = CoreAudioInputDevices.deviceID(forUID: uid) else {
                throw AudioRecorderError.inputDeviceUnavailable(name)
            }
            return selectedDeviceID
        }
    }

    private func waitForPendingTeardown() async {
        guard pendingTeardownCount > 0 else { return }
        await withCheckedContinuation { continuation in
            teardownQueue.async {
                continuation.resume()
            }
        }
    }

    private func releaseInput(flushBuffers: Bool) {
        isRecording = false
        writer = nil
        recordingURL = nil
        activeInputDeviceID = nil
        activeInputDeviceName = nil
        let listenerBox = runningListenerBox
        runningListenerBox = nil
        listenerBox?.markExpectedStop()

        guard let inputQueue else { return }
        self.inputQueue = nil

        if flushBuffers {
            // Stop synchronously and drain callbackQueue so the writer receives
            // all recorded audio before stop() finalizes the WAV file.
            AudioQueueStop(inputQueue, true)
            callbackQueue.sync {}
        }

        // Dispose off the main actor so Core Audio / Bluetooth HAL teardown
        // never stalls the UI or hotkey event loop. Keep `listenerBox` alive
        // until AudioQueueDispose finishes removing the property listener.
        let queueBox = SendableAudioQueueRef(rawValue: inputQueue)
        pendingTeardownCount += 1
        teardownQueue.async { [weak self] in
            AudioQueueDispose(queueBox.rawValue, true)
            _ = listenerBox
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingTeardownCount = max(0, self.pendingTeardownCount - 1)
                // Reopening a Bluetooth input at once after it closes can churn the
                // input/output profiles until macOS drops the headset route. Reject a
                // new recording for a short time after each close.
                self.restartAllowedAt = ContinuousClock().now.advanced(by: Self.teardownDrainDuration)
            }
        }
    }
}

private struct SendableAudioQueueRef: @unchecked Sendable {
    let rawValue: AudioQueueRef
}

protocol TemporaryFileCleaning: Sendable {
    func delete(_ url: URL)
    func cleanupStaleRecordings()
}

extension TemporaryFileCleaning {
    func cleanupStaleRecordings() {}
}

struct TemporaryFileCleaner: TemporaryFileCleaning {
    private let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func cleanupStaleRecordings() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in urls where url.pathExtension == "wav" && url.lastPathComponent.hasPrefix("MacDictate-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
