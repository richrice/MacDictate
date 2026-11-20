import Carbon.HIToolbox
import AppKit
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

    var isProblem: Bool {
        switch self {
        case .conflict, .failed: true
        case .notRegistered, .registered: false
        }
    }
}

enum HotkeySlot: UInt32, Hashable, Sendable {
    case laptop = 1
    case extendedKeyboard = 2
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    @Published private(set) var registrationStatus: HotkeyRegistrationStatus = .notRegistered
    @Published private(set) var extendedKeyboardRegistrationStatus: HotkeyRegistrationStatus = .notRegistered

    /// The combinations Carbon currently owns. These differ from the user's latest picks when
    /// a replacement failed to register and the previous shortcut was put back.
    private var activeShortcuts: [HotkeySlot: HotkeyShortcut] = [:]
    var activeShortcut: HotkeyShortcut? { activeShortcuts[.laptop] }
    var activeExtendedKeyboardShortcut: HotkeyShortcut? { activeShortcuts[.extendedKeyboard] }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    // nonisolated(unsafe): only mutated on the main actor; deinit needs to read
    // them for teardown, which is safe because the object is uniquely referenced.
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?
    private nonisolated(unsafe) var hotkeyRefs: [HotkeySlot: EventHotKeyRef] = [:]
    private nonisolated(unsafe) var globalModifierMonitor: Any?
    private nonisolated(unsafe) var localModifierMonitor: Any?
    private var modifierMonitorSlot: HotkeySlot?
    private var rightControlIsDown = false
    private var pressedSlot: HotkeySlot?
    private let hotkeySignature = OSType(0x4D_44_49_43) // MDIC

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
            extendedKeyboardRegistrationStatus = .failed("Carbon event handler error \(status)")
        }
    }

    deinit {
        // The Carbon handler holds an unretained pointer to self; tear both
        // registrations down so it can never fire against a freed instance.
        for hotkeyRef in hotkeyRefs.values { UnregisterEventHotKey(hotkeyRef) }
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
        if let localModifierMonitor { NSEvent.removeMonitor(localModifierMonitor) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Returns whether `shortcut` became the active hotkey. Registering requires tearing the
    /// current one down first, so a failed attempt would otherwise leave the app with no
    /// working hotkey at all; the previous shortcut is restored instead.
    @discardableResult
    func register(_ shortcut: HotkeyShortcut) -> Bool {
        register(shortcut, for: .laptop)
    }

    @discardableResult
    func register(_ shortcut: HotkeyShortcut, for slot: HotkeySlot) -> Bool {
        let previous = activeShortcuts[slot]
        unregister(slot)

        let status = installHotkey(shortcut, for: slot)
        if status == noErr {
            activeShortcuts[slot] = shortcut
            setStatus(.registered(shortcut.displayName), for: slot)
            AppLogger.hotkey.info("Global hotkey registered: \(shortcut.displayName, privacy: .public)")
            return true
        }

        if status == OSStatus(eventHotKeyExistsErr) {
            setStatus(.conflict(shortcut.displayName), for: slot)
            AppLogger.hotkey.error("Global hotkey conflicts with another registered shortcut")
        } else {
            setStatus(.failed("Carbon error \(status)"), for: slot)
            AppLogger.hotkey.error("Global hotkey registration failed with status \(status)")
        }

        if let previous, previous != shortcut, installHotkey(previous, for: slot) == noErr {
            activeShortcuts[slot] = previous
            AppLogger.hotkey.info("Kept the previously registered global hotkey")
        }
        return false
    }

    func unregister() {
        unregister(.laptop)
        unregister(.extendedKeyboard)
    }

    func unregister(_ slot: HotkeySlot) {
        if let hotkeyRef = hotkeyRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(hotkeyRef)
        }
        if modifierMonitorSlot == slot {
            removeModifierMonitors()
        }
        activeShortcuts[slot] = nil
        if pressedSlot == slot { pressedSlot = nil }
        setStatus(.notRegistered, for: slot)
    }

    func status(for slot: HotkeySlot) -> HotkeyRegistrationStatus {
        switch slot {
        case .laptop: registrationStatus
        case .extendedKeyboard: extendedKeyboardRegistrationStatus
        }
    }

    func activeShortcut(for slot: HotkeySlot) -> HotkeyShortcut? {
        activeShortcuts[slot]
    }

    private func installHotkey(_ shortcut: HotkeyShortcut, for slot: HotkeySlot) -> OSStatus {
        if shortcut == .defaultExtendedKeyboardShortcut {
            return installRightControlMonitor(for: slot)
        }
        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: hotkeySignature, id: slot.rawValue),
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if status == noErr, let hotkeyRef {
            hotkeyRefs[slot] = hotkeyRef
        }
        return status
    }

    private func installRightControlMonitor(for slot: HotkeySlot) -> OSStatus {
        guard modifierMonitorSlot == nil else { return OSStatus(eventHotKeyExistsErr) }

        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.handleRightControlEvent(event)
            }
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.handleRightControlEvent(event)
            }
            return event
        }
        guard globalModifierMonitor != nil, localModifierMonitor != nil else {
            removeModifierMonitors()
            return OSStatus(eventInternalErr)
        }
        modifierMonitorSlot = slot
        return noErr
    }

    private func removeModifierMonitors() {
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
        if let localModifierMonitor { NSEvent.removeMonitor(localModifierMonitor) }
        globalModifierMonitor = nil
        localModifierMonitor = nil
        modifierMonitorSlot = nil
        rightControlIsDown = false
    }

    // NX_DEVICERCTLKEYMASK: distinguishes the right Control key even when left Control is held.
    private static let rightControlDeviceMask: UInt = 0x0000_2000

    private func handleRightControlEvent(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_RightControl),
              let slot = modifierMonitorSlot,
              activeShortcuts[slot] != nil else { return }

        let isDown = event.modifierFlags.rawValue & Self.rightControlDeviceMask != 0
        guard isDown != rightControlIsDown else { return }
        rightControlIsDown = isDown

        if isDown {
            guard pressedSlot == nil else { return }
            pressedSlot = slot
            onKeyDown?()
        } else {
            guard pressedSlot == slot else { return }
            pressedSlot = nil
            onKeyUp?()
        }
    }

    /// If Secure Event Input (for example, a password field) swallowed a Right Control key-up,
    /// `pressedSlot` would remain latched and block other shortcuts. Clear the stale latch when
    /// Right Control is no longer physically held.
    private func clearStuckRightControlIfNeeded() {
        guard let monitorSlot = modifierMonitorSlot,
              pressedSlot == monitorSlot else { return }
        let physicallyDown = NSEvent.modifierFlags.rawValue & Self.rightControlDeviceMask != 0
        guard !physicallyDown else { return }
        rightControlIsDown = false
        pressedSlot = nil
        AppLogger.hotkey.info("Cleared stuck Right Control modifier state after missed key-up")
    }

    private func setStatus(_ status: HotkeyRegistrationStatus, for slot: HotkeySlot) {
        switch slot {
        case .laptop: registrationStatus = status
        case .extendedKeyboard: extendedKeyboardRegistrationStatus = status
        }
    }

    private func handle(kind: UInt32, identifier: UInt32) -> OSStatus {
        guard let slot = HotkeySlot(rawValue: identifier), activeShortcuts[slot] != nil else {
            return OSStatus(eventNotHandledErr)
        }
        switch kind {
        case UInt32(kEventHotKeyPressed):
            clearStuckRightControlIfNeeded()
            guard pressedSlot == nil else { return noErr }
            pressedSlot = slot
            onKeyDown?()
        case UInt32(kEventHotKeyReleased):
            guard pressedSlot == slot else { return noErr }
            pressedSlot = nil
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
