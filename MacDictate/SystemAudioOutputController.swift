import CoreAudio

@MainActor
protocol SystemAudioOutputControlling: AnyObject {
    /// Captures the user's output state before opening the microphone can change
    /// the Bluetooth profile.
    func prepareForDictation()
    /// Mutes the current default output. Repeated calls cover profile changes.
    func muteForDictation()
    /// Applies the pre-dictation state to the original and current output routes.
    func restoreAfterDictation()
}

@MainActor
final class SystemAudioOutputController: SystemAudioOutputControlling {
    private struct SavedState {
        let deviceID: AudioObjectID
        let mute: UInt32?
        let volume: Float32?
    }

    private var savedState: SavedState?

    func prepareForDictation() {
        guard savedState == nil else { return }
        guard let deviceID = defaultOutputDevice() else { return }

        let mute = readUInt32(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute
        )
        let volume = readFloat32(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar
        )
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

    func muteForDictation() {
        if savedState == nil {
            prepareForDictation()
        }
        guard savedState != nil, let deviceID = defaultOutputDevice() else { return }

        if writeUInt32(
            1,
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute
        ) == true {
            return
        }
        if writeFloat32(
            0,
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar
        ) == true {
            return
        }
        AppLogger.audio.warning("Default output device supports neither settable mute nor volume")
    }

    func restoreAfterDictation() {
        guard let savedState else { return }
        let targets = Self.restorationTargets(
            originalDeviceID: savedState.deviceID,
            currentDeviceID: defaultOutputDevice()
        )
        self.savedState = nil

        for deviceID in targets {
            restore(savedState, to: deviceID)
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
           let succeeded = writeFloat32(
               volume,
               deviceID: deviceID,
               selector: kAudioDevicePropertyVolumeScalar
           ) {
            wroteValue = true
            if !succeeded {
                AppLogger.audio.warning("Unable to restore output volume")
            }
        }

        if let mute = state.mute,
           let succeeded = writeUInt32(
               mute,
               deviceID: deviceID,
               selector: kAudioDevicePropertyMute
           ) {
            wroteValue = true
            if !succeeded {
                AppLogger.audio.warning("Unable to restore output mute")
            }
        }

        if !wroteValue {
            AppLogger.audio.warning("Unable to apply the saved output state to an audio route")
        }
    }

    private func defaultOutputDevice() -> AudioObjectID? {
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
