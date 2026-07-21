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
}

