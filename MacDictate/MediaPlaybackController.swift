import AppKit
import CoreAudio
import Foundation

@MainActor
protocol MediaPlaybackControlling: AnyObject {
    /// True when a process other than MacDictate currently has an active output
    /// stream, which is the only reliable public signal that something is
    /// actually audible right now.
    func isOtherProcessPlayingAudio() -> Bool
    /// Posts the system play/pause media key, which every media app treats as a
    /// toggle for whatever it is currently playing.
    func togglePlayPause()
}

/// Quiets playback on output routes that expose no volume or mute control.
/// HDMI displays and many other digital outputs hand volume entirely to the
/// receiving hardware, so CoreAudio cannot attenuate them at all.
@MainActor
final class MediaPlaybackController: MediaPlaybackControlling {
    /// NX_KEYTYPE_PLAY from IOKit's hidsystem/ev_keymap.h.
    private static let playPauseKeyCode = 16
    private static let keyDownState = 0xA
    private static let keyUpState = 0xB
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS.
    private static let auxControlSubtype: Int16 = 8

    func isOtherProcessPlayingAudio() -> Bool {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        for process in audioProcessObjects() {
            guard processID(of: process) != ownProcessID else { continue }
            if readUInt32(process, kAudioProcessPropertyIsRunningOutput) == 1 {
                return true
            }
        }
        return false
    }

    func togglePlayPause() {
        postMediaKey(state: Self.keyDownState)
        postMediaKey(state: Self.keyUpState)
    }

    private func postMediaKey(state: Int) {
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Self.auxControlSubtype,
            data1: (Self.playPauseKeyCode << 16) | (state << 8),
            data2: -1
        ), let cgEvent = event.cgEvent else {
            AppLogger.audio.warning("Unable to build a play/pause media key event")
            return
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    private func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }
        var processes = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        guard !processes.isEmpty,
              AudioObjectGetPropertyData(
                  AudioObjectID(kAudioObjectSystemObject),
                  &address,
                  0,
                  nil,
                  &dataSize,
                  &processes
              ) == noErr else {
            return []
        }
        return processes
    }

    private func processID(of process: AudioObjectID) -> pid_t? {
        readUInt32(process, kAudioProcessPropertyPID)
            .map { pid_t(bitPattern: $0) }
    }

    private func readUInt32(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object,
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
}
