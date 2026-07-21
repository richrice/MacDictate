import Carbon.HIToolbox
import Foundation

enum HotkeyRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case registered(String)
    case conflict(String)
    case failed(String)

    var displayText: String {
        switch self {
        case .notRegistered: "Not registered"
        case let .registered(shortcut): "Registered: \(shortcut)"
        case let .conflict(shortcut): "Shortcut conflict: \(shortcut) is already in use"
        case let .failed(detail): "Registration failed: \(detail)"
        }
    }
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    @Published private(set) var registrationStatus: HotkeyRegistrationStatus = .notRegistered

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    // nonisolated(unsafe): only mutated on the main actor; deinit needs to read
    // them for teardown, which is safe because the object is uniquely referenced.
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?
    private nonisolated(unsafe) var hotkeyRef: EventHotKeyRef?
    private var isPressed = false
    private let hotkeyID = EventHotKeyID(signature: OSType(0x4D_44_49_43), id: 1) // MDIC

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.carbonEventHandler,
            eventTypes.count,
            &eventTypes,
            userData,
            &eventHandler
        )
        if status != noErr {
            registrationStatus = .failed("Carbon event handler error \(status)")
        }
    }

    deinit {
        // The Carbon handler holds an unretained pointer to self; tear both
        // registrations down so it can never fire against a freed instance.
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(_ shortcut: HotkeyShortcut) {
        unregister()
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        switch status {
        case noErr:
            registrationStatus = .registered(shortcut.displayName)
            AppLogger.hotkey.info("Global hotkey registered")
        case OSStatus(eventHotKeyExistsErr):
            registrationStatus = .conflict(shortcut.displayName)
            AppLogger.hotkey.error("Global hotkey conflicts with another application")
        default:
            registrationStatus = .failed("Carbon error \(status)")
            AppLogger.hotkey.error("Global hotkey registration failed with status \(status)")
        }
    }

    func unregister() {
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        hotkeyRef = nil
        isPressed = false
        if case .registered = registrationStatus { registrationStatus = .notRegistered }
    }

    private func handle(kind: UInt32, identifier: UInt32) -> OSStatus {
        guard identifier == hotkeyID.id else { return OSStatus(eventNotHandledErr) }
        switch kind {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return noErr }
            isPressed = true
            onKeyDown?()
        case UInt32(kEventHotKeyReleased):
            guard isPressed else { return noErr }
            isPressed = false
            onKeyUp?()
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    private nonisolated static let carbonEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var receivedID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard parameterStatus == noErr else { return OSStatus(eventNotHandledErr) }
        let kind = GetEventKind(event)
        let identifier = receivedID.id
        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        return MainActor.assumeIsolated {
            manager.handle(kind: kind, identifier: identifier)
        }
    }
}
