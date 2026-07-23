import CoreAudio
import Foundation

@MainActor
protocol SystemAudioOutputControlling: AnyObject {
    /// Captures the user's output state before opening the microphone can change
    /// the Bluetooth profile. A baseline already owned by a rapid sequence of
    /// dictations is preserved instead of being recaptured.
    func prepareForDictation(workflowID: UUID)
    /// Mutes the current default output. Repeated calls cover profile changes.
    func muteForDictation(workflowID: UUID)
    /// Starts verified restoration for the workflow that currently owns mute.
    func restoreAfterDictation(workflowID: UUID)
}

@MainActor
protocol AudioOutputDeviceAccess: AnyObject {
    func defaultOutputDevice() -> AudioObjectID?
    func readMute(deviceID: AudioObjectID) -> UInt32?
    func readVolume(deviceID: AudioObjectID) -> Float32?
    func writeMute(_ value: UInt32, deviceID: AudioObjectID) -> Bool?
    func writeVolume(_ value: Float32, deviceID: AudioObjectID) -> Bool?
}

@MainActor
final class SystemAudioOutputController: SystemAudioOutputControlling {
    private struct SavedState: Equatable {
        let deviceID: AudioObjectID
        let mute: UInt32?
        let volume: Float32?
    }

    private let deviceAccess: AudioOutputDeviceAccess
    private let restorationRetryDelay: Duration
    private let restorationQuietDelay: Duration

    private var savedState: SavedState?
    private var activeWorkflowID: UUID?
    private var restorationTask: Task<Void, Never>?

    init(
        deviceAccess: AudioOutputDeviceAccess = CoreAudioOutputDeviceAccess(),
        restorationRetryDelay: Duration = .milliseconds(100),
        restorationQuietDelay: Duration = .seconds(2)
    ) {
        self.deviceAccess = deviceAccess
        self.restorationRetryDelay = restorationRetryDelay
        self.restorationQuietDelay = restorationQuietDelay
    }

    func prepareForDictation(workflowID: UUID) {
        restorationTask?.cancel()
        restorationTask = nil
        activeWorkflowID = workflowID

        // Keep the first trusted baseline until it has been restored and has
        // remained stable through the quiet period. A rapid follow-up press may
        // otherwise observe our own transient mute as the user's desired state.
        guard savedState == nil else { return }
        guard let deviceID = deviceAccess.defaultOutputDevice() else { return }

        let mute = deviceAccess.readMute(deviceID: deviceID)
        let volume = deviceAccess.readVolume(deviceID: deviceID)
        guard mute != nil || volume != nil else {
            AppLogger.audio.warning("Default output device exposes no readable mute or volume state")
            return
        }
        savedState = SavedState(
            deviceID: deviceID,
            mute: mute,
            volume: volume
        )
    }

    func muteForDictation(workflowID: UUID) {
        guard activeWorkflowID == workflowID else { return }
        if savedState == nil {
            prepareForDictation(workflowID: workflowID)
        }
        guard savedState != nil,
              let deviceID = deviceAccess.defaultOutputDevice() else {
            return
        }

        if deviceAccess.writeMute(1, deviceID: deviceID) == true {
            return
        }
        if deviceAccess.writeVolume(0, deviceID: deviceID) == true {
            return
        }
        AppLogger.audio.warning("Default output device supports neither settable mute nor volume")
    }

    func restoreAfterDictation(workflowID: UUID) {
        // Delayed cleanup from an older press must not restore or discard the
        // state owned by a newer dictation.
        guard activeWorkflowID == workflowID else { return }
        activeWorkflowID = nil
        restorationTask?.cancel()
        restorationTask = nil
        guard let savedState else { return }

        restore(savedState)
        restorationTask = Task { [weak self] in
            await self?.runRestorationWatchdog(expectedState: savedState)
        }
    }

    /// App termination cannot wait for the asynchronous verification loop.
    /// Make one final best-effort write while the process is still alive.
    func restoreImmediately() {
        activeWorkflowID = nil
        restorationTask?.cancel()
        restorationTask = nil
        guard let savedState else { return }
        restore(savedState)
        self.savedState = nil
    }

    private func runRestorationWatchdog(expectedState: SavedState) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: restorationRetryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  activeWorkflowID == nil,
                  savedState == expectedState else {
                return
            }

            if isRestored(expectedState) {
                do {
                    try await Task.sleep(for: restorationQuietDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      activeWorkflowID == nil,
                      savedState == expectedState else {
                    return
                }
                if isRestored(expectedState) {
                    savedState = nil
                    restorationTask = nil
                    return
                }
            }

            // Core Audio and Bluetooth route changes can accept a write before
            // the property has actually settled. Reapply until readback matches.
            restore(expectedState)
        }
    }

    private func isRestored(_ state: SavedState) -> Bool {
        let targets = Self.restorationTargets(
            originalDeviceID: state.deviceID,
            currentDeviceID: deviceAccess.defaultOutputDevice()
        )
        var verifiedRoute = false

        for deviceID in targets {
            guard let matches = route(deviceID, matches: state) else { continue }
            verifiedRoute = true
            if !matches { return false }
        }
        return verifiedRoute
    }

    /// Returns nil when the route currently exposes none of the saved
    /// properties, so another readable route can still verify restoration.
    private func route(
        _ deviceID: AudioObjectID,
        matches state: SavedState
    ) -> Bool? {
        var comparedProperty = false

        if let expectedMute = state.mute,
           let currentMute = deviceAccess.readMute(deviceID: deviceID) {
            comparedProperty = true
            if currentMute != expectedMute { return false }
        }

        if let expectedVolume = state.volume,
           let currentVolume = deviceAccess.readVolume(deviceID: deviceID) {
            comparedProperty = true
            if abs(currentVolume - expectedVolume) > 0.01 { return false }
        }

        return comparedProperty ? true : nil
    }

    private func restore(_ state: SavedState) {
        let targets = Self.restorationTargets(
            originalDeviceID: state.deviceID,
            currentDeviceID: deviceAccess.defaultOutputDevice()
        )
        for deviceID in targets {
            restore(state, to: deviceID)
        }
    }

    static func restorationTargets(
        originalDeviceID: AudioObjectID,
        currentDeviceID: AudioObjectID?
    ) -> [AudioObjectID] {
        guard let currentDeviceID,
              currentDeviceID != originalDeviceID else {
            return [originalDeviceID]
        }
        // Restore the current route last. Both receive the same canonical
        // pre-dictation state, so shared Bluetooth controls cannot end muted.
        return [originalDeviceID, currentDeviceID]
    }

    private func restore(
        _ state: SavedState,
        to deviceID: AudioObjectID
    ) {
        var wroteValue = false

        // Restore volume before unmuting so playback cannot resume at an
        // intermediate level.
        if let volume = state.volume,
           let succeeded = deviceAccess.writeVolume(volume, deviceID: deviceID) {
            wroteValue = true
            if !succeeded {
                AppLogger.audio.warning("Unable to restore output volume")
            }
        }

        if let mute = state.mute,
           let succeeded = deviceAccess.writeMute(mute, deviceID: deviceID) {
            wroteValue = true
            if !succeeded {
                AppLogger.audio.warning("Unable to restore output mute")
            }
        }

        if !wroteValue {
            AppLogger.audio.warning("Unable to apply the saved output state to an audio route")
        }
    }
}

@MainActor
private final class CoreAudioOutputDeviceAccess: AudioOutputDeviceAccess {
    func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else {
            AppLogger.audio.warning("Unable to resolve the default output device (status: \(status, privacy: .public))")
            return nil
        }
        guard deviceID != kAudioObjectUnknown else {
            AppLogger.audio.warning("CoreAudio returned no default output device")
            return nil
        }
        return deviceID
    }

    func readMute(deviceID: AudioObjectID) -> UInt32? {
        readUInt32(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute
        )
    }

    func readVolume(deviceID: AudioObjectID) -> Float32? {
        readFloat32(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar
        )
    }

    func writeMute(_ value: UInt32, deviceID: AudioObjectID) -> Bool? {
        writeUInt32(
            value,
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute
        )
    }

    func writeVolume(_ value: Float32, deviceID: AudioObjectID) -> Bool? {
        writeFloat32(
            value,
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar
        )
    }

    private func readUInt32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = propertyAddress(selector: selector)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private func readFloat32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Float32? {
        var address = propertyAddress(selector: selector)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private func writeUInt32(
        _ value: UInt32,
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = propertyAddress(selector: selector)
        guard isSettable(deviceID: deviceID, address: &address) else {
            return nil
        }
        var mutableValue = value
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        ) == noErr
    }

    private func writeFloat32(
        _ value: Float32,
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = propertyAddress(selector: selector)
        guard isSettable(deviceID: deviceID, address: &address) else {
            return nil
        }
        var mutableValue = value
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableValue
        ) == noErr
    }

    private func isSettable(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(
            deviceID,
            &address,
            &isSettable
        ) == noErr && isSettable.boolValue
    }

    private func propertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
