import CoreAudio
import Foundation

enum SystemAudioSilencingError: LocalizedError, Equatable {
    case processLookupFailed(OSStatus)
    case processObjectUnavailable
    case tapCreationFailed(OSStatus)
    case tapUnavailable

    var errorDescription: String? {
        switch self {
        case let .processLookupFailed(status):
            "System audio could not be silenced (process lookup status: \(status))."
        case .processObjectUnavailable:
            "System audio could not be silenced because MacDictate's audio process was unavailable."
        case let .tapCreationFailed(status):
            "System audio could not be silenced (Core Audio status: \(status))."
        case .tapUnavailable:
            "System audio silencing requires macOS 14.2 or newer."
        }
    }
}

@MainActor
protocol SystemAudioOutputControlling: AnyObject {
    /// Silences every audio process except MacDictate without changing device
    /// volume or media playback state. Repeated calls transfer ownership to the
    /// newest workflow without creating a second tap.
    func silenceForDictation(workflowID: UUID) throws
    /// Removes the mute tap when the workflow that owns it finishes.
    func restoreAfterDictation(workflowID: UUID)
}

@MainActor
protocol ProcessAudioTapAccess: AnyObject {
    func createGlobalMuteTap(excludingProcessID: pid_t) throws -> AudioObjectID
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus
}

@MainActor
final class SystemAudioOutputController: SystemAudioOutputControlling {
    private struct ActiveTap {
        var workflowID: UUID
        let tapID: AudioObjectID
    }

    private let tapAccess: ProcessAudioTapAccess
    private var activeTap: ActiveTap?

    init(tapAccess: ProcessAudioTapAccess = CoreAudioProcessTapAccess()) {
        self.tapAccess = tapAccess
    }

    func silenceForDictation(workflowID: UUID) throws {
        guard #available(macOS 14.2, *) else {
            AppLogger.audio.warning("System audio silencing requires macOS 14.2 or newer")
            return
        }

        if var activeTap {
            activeTap.workflowID = workflowID
            self.activeTap = activeTap
            return
        }

        let tapID = try tapAccess.createGlobalMuteTap(
            excludingProcessID: ProcessInfo.processInfo.processIdentifier
        )
        activeTap = ActiveTap(workflowID: workflowID, tapID: tapID)
        AppLogger.audio.info("Created a private Core Audio mute tap for dictation")
    }

    func restoreAfterDictation(workflowID: UUID) {
        guard let activeTap, activeTap.workflowID == workflowID else { return }
        destroy(activeTap)
    }

    /// App termination gets one final explicit cleanup attempt. A private tap
    /// is also owned by this process, so Core Audio removes it if the process
    /// exits before explicit cleanup succeeds.
    func restoreImmediately() {
        guard let activeTap else { return }
        destroy(activeTap)
    }

    private func destroy(_ tap: ActiveTap) {
        let status = tapAccess.destroyProcessTap(tap.tapID)
        guard status == noErr else {
            AppLogger.audio.error(
                "Unable to destroy the Core Audio mute tap (status: \(status, privacy: .public))"
            )
            return
        }
        if activeTap?.tapID == tap.tapID {
            activeTap = nil
        }
        AppLogger.audio.info("Removed the private Core Audio mute tap")
    }
}

@MainActor
private final class CoreAudioProcessTapAccess: ProcessAudioTapAccess {
    func createGlobalMuteTap(excludingProcessID processID: pid_t) throws -> AudioObjectID {
        guard #available(macOS 14.2, *) else {
            throw SystemAudioSilencingError.tapUnavailable
        }

        let ownProcessObject = try processObjectID(for: processID)
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcessObject]
        )
        description.name = "MacDictate System Audio Silencer"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw SystemAudioSilencingError.tapCreationFailed(status)
        }
        guard tapID != kAudioObjectUnknown else {
            throw SystemAudioSilencingError.tapCreationFailed(kAudioHardwareUnspecifiedError)
        }
        return tapID
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        guard #available(macOS 14.2, *) else { return kAudioHardwareUnsupportedOperationError }
        return AudioHardwareDestroyProcessTap(tapID)
    }

    private func processObjectID(for processID: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableProcessID = processID
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &mutableProcessID,
            &dataSize,
            &processObjectID
        )
        guard status == noErr else {
            throw SystemAudioSilencingError.processLookupFailed(status)
        }
        guard processObjectID != kAudioObjectUnknown else {
            throw SystemAudioSilencingError.processObjectUnavailable
        }
        return processObjectID
    }
}
