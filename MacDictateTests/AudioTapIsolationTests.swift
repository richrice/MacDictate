@preconcurrency import AVFoundation
import XCTest
@testable import MacDictate

private final class AudioTapInvocation: @unchecked Sendable {
    private let block: AVAudioNodeTapBlock
    private let buffer: AVAudioPCMBuffer
    private let time: AVAudioTime

    init(block: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        self.block = block
        self.buffer = buffer
        self.time = time
    }

    func invoke() {
        block(buffer, time)
    }
}

@MainActor
final class AudioTapIsolationTests: XCTestCase {
    func testTapBlockCanRunOffMainActor() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64) else {
            XCTFail("Could not create test audio buffer")
            return
        }
        buffer.frameLength = 64
        let counter = LockedCounter()
        let completed = DispatchSemaphore(value: 0)
        let block = AudioTapBlockFactory.make { _ in
            _ = counter.increment()
        }
        let invocation = AudioTapInvocation(block: block, buffer: buffer, time: AVAudioTime())

        DispatchQueue.global(qos: .userInitiated).async {
            invocation.invoke()
            completed.signal()
        }

        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(counter.value, 1)
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
}
