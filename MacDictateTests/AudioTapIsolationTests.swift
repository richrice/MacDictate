@preconcurrency import AVFoundation
import AudioToolbox
import XCTest
@testable import MacDictate

private final class AudioQueueInputInvocation: @unchecked Sendable {
    private let block: AudioQueueInputCallbackBlock
    private let queue: AudioQueueRef
    private let buffer: AudioQueueBufferRef

    init(block: @escaping AudioQueueInputCallbackBlock, queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        self.block = block
        self.queue = queue
        self.buffer = buffer
    }

    func invoke() {
        var timeStamp = AudioTimeStamp()
        block(queue, buffer, &timeStamp, 0, nil)
    }
}

private final class LockedPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Float = 0

    var value: Float {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        lock.lock()
        defer { lock.unlock() }
        storedValue = samples.map(abs).max() ?? 0
    }
}

@MainActor
final class AudioTapIsolationTests: XCTestCase {
    func testQueueInputBlockCanRunOffMainActor() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var queue: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(
            &queue,
            format.streamDescription,
            0,
            DispatchQueue(label: "AudioTapIsolationTests"),
            // A closure written here inherits main-actor isolation and traps
            // when the queue calls it. The factory makes a nonisolated block.
            AudioQueueInputBlockFactory.make(format: format) { _ in }
        )
        guard status == noErr, let queue else {
            throw XCTSkip("This Mac has no input device for an audio queue (Core Audio error \(status)).")
        }
        defer { AudioQueueDispose(queue, true) }

        let frameCount = 64
        var queueBuffer: AudioQueueBufferRef?
        XCTAssertEqual(AudioQueueAllocateBuffer(queue, UInt32(frameCount * 4), &queueBuffer), noErr)
        let buffer = try XCTUnwrap(queueBuffer)
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        for index in 0..<frameCount { samples[index] = 0.25 }
        buffer.pointee.mAudioDataByteSize = UInt32(frameCount * 4)

        let peak = LockedPeak()
        let completed = DispatchSemaphore(value: 0)
        let block = AudioQueueInputBlockFactory.make(format: format) { buffer in
            peak.record(buffer)
        }
        let invocation = AudioQueueInputInvocation(block: block, queue: queue, buffer: buffer)

        DispatchQueue.global(qos: .userInitiated).async {
            invocation.invoke()
            completed.signal()
        }

        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(peak.value, 0.25, accuracy: 0.001)
    }

    func testAudioRecorderPrepareAndCancelSucceedsWithRealAudioQueue() async throws {
        final class AlwaysGrantedMicPermission: MicrophonePermissionProviding {
            func request() async -> Bool { true }
        }
        let recorder = AudioRecorder(permissionManager: AlwaysGrantedMicPermission())
        guard !recorder.availableInputDevices.isEmpty else {
            throw XCTSkip("This Mac has no input device available for AudioRecorder.")
        }
        try await recorder.prepare()
        recorder.cancel()
    }

    func testWriterRebuildsConverterWhenInputFormatChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDictate-format-change-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let initialFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let changedFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 4_410) else {
            XCTFail("Could not create test formats")
            return
        }
        buffer.frameLength = 4_410
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(buffer.frameLength) { samples[index] = 0.25 }
        }

        // The writer was configured for 48 kHz mono; a device switch delivers
        // 44.1 kHz stereo. It must rebuild its converter and keep recording.
        let writer = try LockedAudioWriter(url: url, inputFormat: initialFormat)
        writer.append(buffer)
        XCTAssertEqual(writer.livePeakAmplitude, 0.25, accuracy: 0.01)
        let result = try writer.finish()

        XCTAssertGreaterThan(result.frames, 0)
        XCTAssertEqual(result.peak, 0.25, accuracy: 0.01)
        XCTAssertGreaterThan(result.rms, 0.1)
    }

    func testAudioLevelScaleMapsSilenceAndSpeechIntoMeterRange() {
        XCTAssertEqual(AudioLevelScale.normalized(peakAmplitude: 0), 0)
        XCTAssertEqual(AudioLevelScale.normalized(peakAmplitude: 0.001), 0, accuracy: 0.001)
        XCTAssertEqual(AudioLevelScale.normalized(peakAmplitude: 0.1), 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(AudioLevelScale.normalized(peakAmplitude: 1), 1, accuracy: 0.001)
    }

    func testRunningListenerBoxFiresOnlyOnUnexpectedStopAfterStart() {
        let fireCount = LockedCounter()
        let box = AudioQueueRunningListenerBox {
            _ = fireCount.increment()
        }

        // Before start, a stop callback must be ignored.
        box.notifyStopped()
        XCTAssertEqual(fireCount.value, 0)

        // After start, an unexpected stop fires exactly once.
        box.markStarted()
        box.notifyStopped()
        box.notifyStopped()
        XCTAssertEqual(fireCount.value, 1)

        // Expected stops never fire.
        let expectedCount = LockedCounter()
        let expectedBox = AudioQueueRunningListenerBox {
            _ = expectedCount.increment()
        }
        expectedBox.markStarted()
        expectedBox.markExpectedStop()
        expectedBox.notifyStopped()
        XCTAssertEqual(expectedCount.value, 0)
    }

    func testTemporaryFileCleanerSweepsOnlyStaleMacDictateWavs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDictateCleanerTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let staleWav = directory.appendingPathComponent("MacDictate-stale.wav")
        let otherWav = directory.appendingPathComponent("other.wav")
        let otherTxt = directory.appendingPathComponent("MacDictate-note.txt")
        try Data("a".utf8).write(to: staleWav)
        try Data("b".utf8).write(to: otherWav)
        try Data("c".utf8).write(to: otherTxt)

        let cleaner = TemporaryFileCleaner(directory: directory)
        cleaner.cleanupStaleRecordings()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleWav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherWav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherTxt.path))
    }
}
