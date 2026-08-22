import CoreAudio
import XCTest
@testable import MacDictate

@MainActor
private final class MockAudioOutputDeviceAccess: AudioOutputDeviceAccess {
    var defaultDeviceID: AudioObjectID? = 1
    var muteValues: [AudioObjectID: UInt32] = [1: 0]
    var volumeValues: [AudioObjectID: Float32] = [1: 0.7]
    var supportsMute = true
    var supportsVolume = true
    var ignoredUnmuteWrites = 0
    var ignoredPositiveVolumeWrites = 0
    private(set) var unmuteWriteCount = 0

    func defaultOutputDevice() -> AudioObjectID? {
        defaultDeviceID
    }

    func readMute(deviceID: AudioObjectID) -> UInt32? {
        supportsMute ? muteValues[deviceID] : nil
    }

    func readVolume(deviceID: AudioObjectID) -> Float32? {
        supportsVolume ? volumeValues[deviceID] : nil
    }

    func writeMute(_ value: UInt32, deviceID: AudioObjectID) -> Bool? {
        guard supportsMute else { return nil }
        if value == 0 {
            unmuteWriteCount += 1
            if ignoredUnmuteWrites > 0 {
                ignoredUnmuteWrites -= 1
                return true
            }
        }
        muteValues[deviceID] = value
        return true
    }

    func writeVolume(_ value: Float32, deviceID: AudioObjectID) -> Bool? {
        guard supportsVolume else { return nil }
        if value > 0, ignoredPositiveVolumeWrites > 0 {
            ignoredPositiveVolumeWrites -= 1
            return true
        }
        volumeValues[deviceID] = value
        return true
    }
}

@MainActor
private final class MockMediaPlaybackController: MediaPlaybackControlling {
    var otherProcessIsPlaying = false
    private(set) var toggleCount = 0

    func isOtherProcessPlayingAudio() -> Bool {
        otherProcessIsPlaying
    }

    func togglePlayPause() {
        toggleCount += 1
        otherProcessIsPlaying.toggle()
    }
}

@MainActor
private final class FakeClock {
    private var current = Date(timeIntervalSinceReferenceDate: 0)
    func now() -> Date { current }
    func advance(by interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

@MainActor
final class SystemAudioOutputControllerTests: XCTestCase {
    private func makeController(
        access: MockAudioOutputDeviceAccess,
        playback: MediaPlaybackControlling = MockMediaPlaybackController(),
        quietDelay: Duration = .milliseconds(40),
        clock: FakeClock = FakeClock()
    ) -> SystemAudioOutputController {
        SystemAudioOutputController(
            deviceAccess: access,
            playbackController: playback,
            restorationRetryDelay: .milliseconds(10),
            restorationQuietDelay: quietDelay,
            now: { clock.now() }
        )
    }

    /// An HDMI display exposes neither mute nor volume, so nothing can be
    /// attenuated and playback has to be paused instead.
    private func makeUncontrollableAccess() -> MockAudioOutputDeviceAccess {
        let access = MockAudioOutputDeviceAccess()
        access.supportsMute = false
        access.supportsVolume = false
        return access
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), description)
    }

    func testRestorationRetriesUntilDeviceReadbackMatchesBaseline() async {
        let access = MockAudioOutputDeviceAccess()
        let controller = makeController(access: access)
        let workflowID = UUID()

        controller.prepareForDictation(workflowID: workflowID)
        controller.muteForDictation(workflowID: workflowID)
        access.ignoredUnmuteWrites = 2
        controller.restoreAfterDictation(workflowID: workflowID)

        XCTAssertEqual(access.muteValues[1], 1)
        await waitFor("watchdog should eventually restore mute state") {
            access.muteValues[1] == 0
        }
        XCTAssertGreaterThanOrEqual(access.unmuteWriteCount, 3)
    }

    func testRapidPressReusesTrustedBaselineInsteadOfRecapturingMute() async {
        let access = MockAudioOutputDeviceAccess()
        access.volumeValues[1] = 0.72
        let controller = makeController(access: access)
        let firstWorkflowID = UUID()

        controller.prepareForDictation(workflowID: firstWorkflowID)
        controller.muteForDictation(workflowID: firstWorkflowID)
        access.ignoredUnmuteWrites = 1
        controller.restoreAfterDictation(workflowID: firstWorkflowID)
        XCTAssertEqual(access.muteValues[1], 1)

        // Begin again before verification. The device currently reports muted,
        // but that value belongs to MacDictate and must not replace the baseline.
        let secondWorkflowID = UUID()
        controller.prepareForDictation(workflowID: secondWorkflowID)
        access.ignoredUnmuteWrites = 0
        controller.muteForDictation(workflowID: secondWorkflowID)
        controller.restoreAfterDictation(workflowID: secondWorkflowID)

        await waitFor("second workflow should restore the original baseline") {
            access.muteValues[1] == 0
        }
        XCTAssertEqual(access.volumeValues[1], Float32(0.72))
    }

    func testRapidPressDoesNotRecaptureFallbackVolumeOfZero() async {
        let access = MockAudioOutputDeviceAccess()
        access.supportsMute = false
        access.volumeValues[1] = 0.63
        let controller = makeController(access: access)
        let firstWorkflowID = UUID()

        controller.prepareForDictation(workflowID: firstWorkflowID)
        controller.muteForDictation(workflowID: firstWorkflowID)
        XCTAssertEqual(access.volumeValues[1], 0)

        access.ignoredPositiveVolumeWrites = 1
        controller.restoreAfterDictation(workflowID: firstWorkflowID)
        XCTAssertEqual(access.volumeValues[1], 0)

        let secondWorkflowID = UUID()
        controller.prepareForDictation(workflowID: secondWorkflowID)
        access.ignoredPositiveVolumeWrites = 0
        controller.muteForDictation(workflowID: secondWorkflowID)
        controller.restoreAfterDictation(workflowID: secondWorkflowID)

        await waitFor("fallback route should restore its original volume") {
            access.volumeValues[1] == Float32(0.63)
        }
    }

    func testUncontrollableRoutePausesAndResumesPlayback() {
        let access = makeUncontrollableAccess()
        let playback = MockMediaPlaybackController()
        playback.otherProcessIsPlaying = true
        let clock = FakeClock()
        let controller = makeController(access: access, playback: playback, clock: clock)
        let workflowID = UUID()

        controller.prepareForDictation(workflowID: workflowID)
        controller.muteForDictation(workflowID: workflowID)
        XCTAssertEqual(playback.toggleCount, 0)

        clock.advance(by: SystemAudioOutputController.playbackConfirmationDelay + 0.1)
        controller.muteForDictation(workflowID: workflowID)
        XCTAssertEqual(playback.toggleCount, 1)
        XCTAssertFalse(playback.isOtherProcessPlayingAudio())

        controller.restoreAfterDictation(workflowID: workflowID)
        XCTAssertEqual(playback.toggleCount, 2)
        XCTAssertTrue(playback.isOtherProcessPlayingAudio())
    }

    func testRepeatedMuteCallsPausePlaybackOnlyOnce() {
        let access = makeUncontrollableAccess()
        let playback = MockMediaPlaybackController()
        playback.otherProcessIsPlaying = true
        let clock = FakeClock()
        let controller = makeController(access: access, playback: playback, clock: clock)
        let workflowID = UUID()

        controller.prepareForDictation(workflowID: workflowID)
        // The coordinator re-mutes every 100ms to cover route changes; the
        // toggle must fire once after the playing signal is sustained and must
        // not flip playback back on.
        for step in 0..<8 {
            if step > 0 { clock.advance(by: 0.1) }
            controller.muteForDictation(workflowID: workflowID)
        }

        XCTAssertEqual(playback.toggleCount, 1)
        XCTAssertFalse(playback.isOtherProcessPlayingAudio())
    }

    func testBrieflyReportedPlayingSignalDoesNotUnpauseAlreadyPausedMedia() {
        let access = makeUncontrollableAccess()
        let playback = MockMediaPlaybackController()
        // Media is paused; the OS can still report an active output stream
        // while the stream tears down. The signal settles below the
        // confirmation window and must never reach the toggle.
        playback.otherProcessIsPlaying = true
        let clock = FakeClock()
        let controller = makeController(access: access, playback: playback, clock: clock)
        let workflowID = UUID()

        controller.prepareForDictation(workflowID: workflowID)
        controller.muteForDictation(workflowID: workflowID)

        playback.otherProcessIsPlaying = false
        clock.advance(by: SystemAudioOutputController.playbackConfirmationDelay * 2)
        controller.muteForDictation(workflowID: workflowID)

        XCTAssertEqual(playback.toggleCount, 0)
        controller.restoreAfterDictation(workflowID: workflowID)
        XCTAssertEqual(playback.toggleCount, 0)
        XCTAssertFalse(playback.isOtherProcessPlayingAudio())
    }

    func testSilentRouteIsNotToggledIntoPlayback() {
        let access = makeUncontrollableAccess()
        let playback = MockMediaPlaybackController()
        playback.otherProcessIsPlaying = false
        let controller = makeController(access: access, playback: playback)
        let workflowID = UUID()

        controller.prepareForDictation(workflowID: workflowID)
        controller.muteForDictation(workflowID: workflowID)
        controller.restoreAfterDictation(workflowID: workflowID)

        XCTAssertEqual(playback.toggleCount, 0)
    }

    func testControllableRouteMutesWithoutTouchingPlayback() {
        let access = MockAudioOutputDeviceAccess()
        let playback = MockMediaPlaybackController()
        playback.otherProcessIsPlaying = true
        let controller = makeController(access: access, playback: playback)
        let workflowID = UUID()

        controller.prepareForDictation(workflowID: workflowID)
        controller.muteForDictation(workflowID: workflowID)

        XCTAssertEqual(access.muteValues[1], 1)
        XCTAssertEqual(playback.toggleCount, 0)
    }

    func testTerminationResumesPausedPlayback() {
        let access = makeUncontrollableAccess()
        let playback = MockMediaPlaybackController()
        playback.otherProcessIsPlaying = true
        let clock = FakeClock()
        let controller = makeController(access: access, playback: playback, clock: clock)
        let workflowID = UUID()

        controller.prepareForDictation(workflowID: workflowID)
        controller.muteForDictation(workflowID: workflowID)
        clock.advance(by: SystemAudioOutputController.playbackConfirmationDelay + 0.1)
        controller.muteForDictation(workflowID: workflowID)
        controller.restoreImmediately()

        XCTAssertEqual(playback.toggleCount, 2)
        XCTAssertTrue(playback.isOtherProcessPlayingAudio())
    }

    func testStaleWorkflowCannotRestoreAudioOwnedByNewWorkflow() async {
        let access = MockAudioOutputDeviceAccess()
        let controller = makeController(access: access)
        let firstWorkflowID = UUID()
        let secondWorkflowID = UUID()

        controller.prepareForDictation(workflowID: firstWorkflowID)
        controller.muteForDictation(workflowID: firstWorkflowID)
        controller.prepareForDictation(workflowID: secondWorkflowID)
        controller.muteForDictation(workflowID: secondWorkflowID)

        controller.restoreAfterDictation(workflowID: firstWorkflowID)
        XCTAssertEqual(access.muteValues[1], 1)

        controller.restoreAfterDictation(workflowID: secondWorkflowID)
        await waitFor("current owner should restore audio") {
            access.muteValues[1] == 0
        }
    }

    func testNewBaselineIsCapturedAfterVerifiedQuietPeriod() async {
        let access = MockAudioOutputDeviceAccess()
        let controller = makeController(
            access: access,
            quietDelay: .milliseconds(20)
        )
        let firstWorkflowID = UUID()

        controller.prepareForDictation(workflowID: firstWorkflowID)
        controller.muteForDictation(workflowID: firstWorkflowID)
        controller.restoreAfterDictation(workflowID: firstWorkflowID)
        await waitFor("first baseline should restore") {
            access.muteValues[1] == 0
        }
        try? await Task.sleep(for: .milliseconds(50))

        // A genuinely fresh series should honor a user volume change made
        // after the previous baseline was verified and released.
        access.volumeValues[1] = 0.35
        let secondWorkflowID = UUID()
        controller.prepareForDictation(workflowID: secondWorkflowID)
        controller.muteForDictation(workflowID: secondWorkflowID)
        controller.restoreAfterDictation(workflowID: secondWorkflowID)

        await waitFor("fresh baseline should restore") {
            access.muteValues[1] == 0
        }
        XCTAssertEqual(access.volumeValues[1], Float32(0.35))
    }
}
