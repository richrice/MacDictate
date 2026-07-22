import CoreAudio

@MainActor
protocol SystemAudioOutputControlling: AnyObject {
    /// Mutes the current default output device, remembering its prior state.
    /// Idempotent: calling while already muted-by-us is a no-op.
    func muteForDictation()
    /// Restores the state saved by muteForDictation and clears it.
    /// Idempotent: calling with nothing saved is a no-op.
    func restoreAfterDictation()
}

@MainActor
final class SystemAudioOutputController: SystemAudioOutputControlling {
    private enum SavedValue {
        case mute(UInt32)
        case volume(Float32)
    }

    private struct SavedState {
        let deviceID: AudioObjectID
        let value: SavedValue
    }

    private var savedState: SavedState?

    func muteForDictation() {
        guard savedState == nil else { return }
        guard let deviceID = defaultOutputDevice() else { return }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var isSettable = DarwinBoolean(false)
            let settableStatus = AudioObjectIsPropertySettable(deviceID, &muteAddress, &isSettable)
            guard settableStatus == noErr else {
                AppLogger.audio.warning("Unable to determine whether output mute is settable (status: \(settableStatus, privacy: .public))")
                return
            }

            if isSettable.boolValue {
                mute(deviceID: deviceID, address: &muteAddress)
                return
            }
        }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &volumeAddress) else {
            AppLogger.audio.warning("Default output device supports neither settable mute nor volume")
            return
        }

        var isVolumeSettable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &volumeAddress, &isVolumeSettable)
        guard settableStatus == noErr else {
            AppLogger.audio.warning("Unable to determine whether output volume is settable (status: \(settableStatus, privacy: .public))")
            return
        }
        guard isVolumeSettable.boolValue else {
            AppLogger.audio.warning("Default output device supports neither settable mute nor volume")
            return
        }

        muteVolume(deviceID: deviceID, address: &volumeAddress)
    }

    func restoreAfterDictation() {
        guard let state = savedState else { return }

        switch state.value {
        case .mute(var originalValue):
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                state.deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &originalValue
            )
            if status != noErr {
                AppLogger.audio.warning("Unable to restore output mute (status: \(status, privacy: .public))")
            }

        case .volume(var originalValue):
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                state.deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &originalValue
            )
            if status != noErr {
                AppLogger.audio.warning("Unable to restore output volume (status: \(status, privacy: .public))")
            }
        }

        savedState = nil
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

    private func mute(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) {
        var originalValue: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let readStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &originalValue
        )
        guard readStatus == noErr else {
            AppLogger.audio.warning("Unable to read output mute (status: \(readStatus, privacy: .public))")
            return
        }

        var mutedValue: UInt32 = 1
        let writeStatus = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutedValue
        )
        guard writeStatus == noErr else {
            AppLogger.audio.warning("Unable to mute output (status: \(writeStatus, privacy: .public))")
            return
        }

        savedState = SavedState(deviceID: deviceID, value: .mute(originalValue))
    }

    private func muteVolume(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) {
        var originalValue: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let readStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &originalValue
        )
        guard readStatus == noErr else {
            AppLogger.audio.warning("Unable to read output volume (status: \(readStatus, privacy: .public))")
            return
        }

        var mutedValue: Float32 = 0
        let writeStatus = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutedValue
        )
        guard writeStatus == noErr else {
            AppLogger.audio.warning("Unable to set output volume to zero (status: \(writeStatus, privacy: .public))")
            return
        }

        savedState = SavedState(deviceID: deviceID, value: .volume(originalValue))
    }
}
