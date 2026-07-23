import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct TargetApplication: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
}

enum TextInsertionOutcome: Equatable, Sendable {
    case accessibility
    case keyboardEvents
    case clipboardPaste
    case pasteDispatched
    case automaticInsertionUnverified
    case copiedForManualPaste
}

enum EventTextInsertionResult: Equatable, Sendable {
    case verified
    case failed
    case unverified
}

enum TextInsertionError: LocalizedError, Equatable {
    case targetUnavailable
    case targetActivationFailed
    case accessibilityRejected(String)
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .targetUnavailable: "The application that was focused when recording began is no longer available."
        case .targetActivationFailed: "The target application could not be focused for text insertion."
        case let .accessibilityRejected(detail): "The target application rejected text insertion. \(detail)"
        case .eventCreationFailed: "macOS could not create the paste keyboard event."
        }
    }
}

@MainActor
protocol DirectTextInserting: AnyObject {
    func insertDirectly(_ text: String, target: TargetApplication) async throws -> EventTextInsertionResult
}

@MainActor
protocol KeyboardTextInserting: AnyObject {
    func type(_ text: String, target: TargetApplication) async throws -> EventTextInsertionResult
}

@MainActor
protocol PasteTextInserting: AnyObject {
    func paste(_ text: String, target: TargetApplication) async throws -> EventTextInsertionResult
}

@MainActor
protocol TextInsertionService: AnyObject {
    func insert(_ text: String, target: TargetApplication) async throws -> TextInsertionOutcome
    func copy(_ text: String)
}

@MainActor
final class AccessibilityDirectInserter: DirectTextInserting {
    private let verificationTimeout: Duration

    init(verificationTimeout: Duration = .milliseconds(800)) {
        self.verificationTimeout = verificationTimeout
    }

    func insertDirectly(
        _ text: String,
        target: TargetApplication
    ) async throws -> EventTextInsertionResult {
        guard let runningApplication = NSRunningApplication(processIdentifier: target.processIdentifier),
              !runningApplication.isTerminated else {
            throw TextInsertionError.targetUnavailable
        }
        if !runningApplication.isActive {
            runningApplication.activate(options: [])
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        if result == .success, let currentFocusedValue = focusedValue {
            if CFGetTypeID(currentFocusedValue) != AXUIElementGetTypeID() {
                focusedValue = nil
                result = .cannotComplete
            } else {
                let candidate = unsafeDowncast(currentFocusedValue, to: AXUIElement.self)
                var focusedPID = pid_t()
                if AXUIElementGetPid(candidate, &focusedPID) != .success || focusedPID != target.processIdentifier {
                    // Activation is asynchronous; never insert into a different app's focused control.
                    focusedValue = nil
                    result = .cannotComplete
                }
            }
        }

        if result != .success || focusedValue == nil {
            let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
            result = AXUIElementCopyAttributeValue(
                applicationElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
        }

        guard result == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw TextInsertionError.accessibilityRejected("Focused element lookup returned \(result.rawValue).")
        }
        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableResult == .success, isSettable.boolValue else {
            throw TextInsertionError.accessibilityRejected("The selected-text attribute is not writable.")
        }
        let verification = AccessibilityTextChangeVerification.capture(
            inserting: text,
            element: focusedElement
        )
        let insertionResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard insertionResult == .success else {
            throw TextInsertionError.accessibilityRejected("AX error \(insertionResult.rawValue).")
        }
        return try await verification.result(timeout: verificationTimeout)
    }
}

@MainActor
final class UnicodeKeyboardTextInserter: KeyboardTextInserting {
    private let maximumChunkUTF16Length: Int
    private let chunkDelay: Duration
    private let verificationTimeout: Duration

    init(
        maximumChunkUTF16Length: Int = 20,
        chunkDelay: Duration = .milliseconds(4),
        verificationTimeout: Duration = .seconds(1)
    ) {
        precondition(maximumChunkUTF16Length > 0)
        self.maximumChunkUTF16Length = maximumChunkUTF16Length
        self.chunkDelay = chunkDelay
        self.verificationTimeout = verificationTimeout
    }

    func type(_ text: String, target: TargetApplication) async throws -> EventTextInsertionResult {
        guard let runningApplication = NSRunningApplication(processIdentifier: target.processIdentifier),
              !runningApplication.isTerminated else {
            throw TextInsertionError.targetUnavailable
        }
        if !runningApplication.isActive {
            runningApplication.activate(options: [])
            try await Task.sleep(for: .milliseconds(120))
        }
        try await waitForPhysicalModifierRelease()

        let verification = AccessibilityTextChangeVerification.capture(
            inserting: text,
            target: target
        )
        let source = CGEventSource(stateID: .privateState)
        let eventPairs = try Self.chunks(text, maximumUTF16Length: maximumChunkUTF16Length).map { chunk in
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw TextInsertionError.eventCreationFailed
            }
            let utf16 = Array(chunk.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            return (keyDown, keyUp)
        }

        for (index, pair) in eventPairs.enumerated() {
            pair.0.postToPid(target.processIdentifier)
            pair.1.postToPid(target.processIdentifier)
            if index + 1 < eventPairs.count {
                try await Task.sleep(for: chunkDelay)
            }
        }

        return try await verification.result(timeout: verificationTimeout)
    }

    static func chunks(_ text: String, maximumUTF16Length: Int) -> [String] {
        precondition(maximumUTF16Length > 0)
        var chunks: [String] = []
        var current = ""
        var currentLength = 0

        for character in text {
            let characterText = String(character)
            let characterLength = characterText.utf16.count
            if !current.isEmpty, currentLength + characterLength > maximumUTF16Length {
                chunks.append(current)
                current = ""
                currentLength = 0
            }
            current.append(character)
            currentLength += characterLength
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

@MainActor
final class ClipboardPasteInserter: PasteTextInserting {
    private let clipboard: ClipboardManaging
    private let pasteDelayNanoseconds: UInt64

    init(clipboard: ClipboardManaging, pasteDelayNanoseconds: UInt64 = 700_000_000) {
        self.clipboard = clipboard
        self.pasteDelayNanoseconds = pasteDelayNanoseconds
    }

    func paste(_ text: String, target: TargetApplication) async throws -> EventTextInsertionResult {
        guard let runningApplication = NSRunningApplication(processIdentifier: target.processIdentifier),
              !runningApplication.isTerminated else {
            throw TextInsertionError.targetUnavailable
        }
        let snapshot = clipboard.snapshot()
        let transcriptChangeCount = clipboard.writeText(text, transient: true)
        do {
            if !runningApplication.isActive {
                runningApplication.activate(options: [])
                try await Task.sleep(for: .milliseconds(120))
            }
            // If the user still physically holds the hotkey modifiers, some apps
            // combine them with the synthetic event and see ⌘⌥V instead of ⌘V.
            try await waitForPhysicalModifierRelease()
            let verification = AccessibilityTextChangeVerification.capture(
                inserting: text,
                target: target
            )

            let requiresFrontmostHIDEvents = Self.requiresFrontmostHIDEvents(
                bundleIdentifier: target.bundleIdentifier
            )
            let source = CGEventSource(
                stateID: requiresFrontmostHIDEvents ? .hidSystemState : .privateState
            )
            let pasteKeyCode = Self.pasteVirtualKeyCode()
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false) else {
                throw TextInsertionError.eventCreationFailed
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand

            if requiresFrontmostHIDEvents {
                try await waitUntilFrontmost(target)
                keyDown.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(12))
                keyUp.post(tap: .cghidEventTap)
            } else {
                keyDown.postToPid(target.processIdentifier)
                keyUp.postToPid(target.processIdentifier)
            }

            let result = try await verification.result(
                timeout: requiresFrontmostHIDEvents
                    ? .seconds(2)
                    : .nanoseconds(Int64(pasteDelayNanoseconds))
            )
            _ = clipboard.restore(snapshot, ifChangeCountIs: transcriptChangeCount)
            return result
        } catch {
            _ = clipboard.restore(snapshot, ifChangeCountIs: transcriptChangeCount)
            throw error
        }
    }

    static func requiresFrontmostHIDEvents(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.openai.codex"
            || bundleIdentifier == "com.googlecode.iterm2"
    }

    private static func pasteVirtualKeyCode() -> CGKeyCode {
        let qwertyVKeyCode = CGKeyCode(9)
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(
                  inputSource,
                  kTISPropertyUnicodeKeyLayoutData
              ) else {
            return qwertyVKeyCode
        }

        let layoutData = Unmanaged<CFData>
            .fromOpaque(rawLayoutData)
            .takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(
                to: UCKeyboardLayout.self
            ) else {
                return qwertyVKeyCode
            }

            var characters = [UniChar](repeating: 0, count: 4)
            let keyboardType = UInt32(LMGetKbdType())
            for keyCode in UInt16(0)..<UInt16(128) {
                var deadKeyState = UInt32(0)
                var characterCount = 0
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    characters.count,
                    &characterCount,
                    &characters
                )
                if status == noErr,
                   characterCount > 0,
                   Unicode.Scalar(characters[0]) == "v" {
                    return CGKeyCode(keyCode)
                }
            }
            return qwertyVKeyCode
        }
    }
}

@MainActor
private struct AccessibilityTextChangeVerification {
    private let element: AXUIElement?
    private let originalValue: String?
    private let expectedValue: String?

    static func capture(inserting text: String, target: TargetApplication) -> Self {
        guard let element = focusedElement(for: target) else {
            return Self(element: nil, originalValue: nil, expectedValue: nil)
        }

        return capture(inserting: text, element: element)
    }

    static func capture(inserting text: String, element: AXUIElement) -> Self {
        guard let originalValue = stringAttribute(kAXValueAttribute, of: element) else {
            return Self(element: nil, originalValue: nil, expectedValue: nil)
        }

        let expectedValue = selectedRange(of: element).flatMap { range -> String? in
            guard range.location >= 0,
                  range.length >= 0,
                  range.location + range.length <= originalValue.utf16.count else {
                return nil
            }
            return (originalValue as NSString).replacingCharacters(
                in: NSRange(location: range.location, length: range.length),
                with: text
            )
        }
        return Self(
            element: element,
            originalValue: originalValue,
            expectedValue: expectedValue
        )
    }

    func result(timeout: Duration) async throws -> EventTextInsertionResult {
        guard let element, let originalValue else {
            try await Task.sleep(for: timeout)
            return .unverified
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var couldReadAfterInsertion = false
        var observedAnyChange = false
        var expectedValueObservedAt: ContinuousClock.Instant?
        repeat {
            try Task.checkCancellation()
            if let currentValue = Self.stringAttribute(kAXValueAttribute, of: element) {
                couldReadAfterInsertion = true
                let now = clock.now
                if let expectedValue, currentValue == expectedValue {
                    let firstObservation = expectedValueObservedAt ?? now
                    expectedValueObservedAt = firstObservation
                    if firstObservation.duration(to: now) >= .milliseconds(300) {
                        return .verified
                    }
                } else {
                    expectedValueObservedAt = nil
                }
                if currentValue != originalValue { observedAnyChange = true }
            }
            guard clock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(25))
        } while true

        guard couldReadAfterInsertion,
              expectedValue != nil,
              !observedAnyChange else {
            return .unverified
        }
        return .failed
    }

    private static func focusedElement(for target: TargetApplication) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard result == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var focusedPID = pid_t()
        guard AXUIElementGetPid(element, &focusedPID) == .success,
              focusedPID == target.processIdentifier else {
            return nil
        }
        return element
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: CFString.self) as String
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }
}

@MainActor
private func waitForPhysicalModifierRelease() async throws {
    let deadline = Date().addingTimeInterval(1.0)
    while !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
          Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
}

@MainActor
private func waitUntilFrontmost(_ target: TargetApplication) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(600))
    repeat {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            return
        }
        NSRunningApplication(processIdentifier: target.processIdentifier)?.activate(options: [])
        try await Task.sleep(for: .milliseconds(25))
    } while clock.now < deadline
    throw TextInsertionError.targetActivationFailed
}

@MainActor
final class DefaultTextInsertionService: TextInsertionService {
    private let permissionManager: AccessibilityPermissionProviding
    private let directInserter: DirectTextInserting
    private let keyboardInserter: KeyboardTextInserting
    private let pasteInserter: PasteTextInserting
    private let clipboard: ClipboardManaging

    init(
        permissionManager: AccessibilityPermissionProviding,
        directInserter: DirectTextInserting,
        keyboardInserter: KeyboardTextInserting,
        pasteInserter: PasteTextInserting,
        clipboard: ClipboardManaging
    ) {
        self.permissionManager = permissionManager
        self.directInserter = directInserter
        self.keyboardInserter = keyboardInserter
        self.pasteInserter = pasteInserter
        self.clipboard = clipboard
    }

    func insert(_ text: String, target: TargetApplication) async throws -> TextInsertionOutcome {
        guard permissionManager.requestIfNeeded() else {
            clipboard.writeText(text)
            return .copiedForManualPaste
        }

        if target.bundleIdentifier == "com.openai.codex"
            || target.bundleIdentifier == "com.googlecode.iterm2" {
            AppLogger.insertion.info(
                "Using focused paste delivery for \(target.name, privacy: .public)"
            )
            switch try await pasteInserter.paste(text, target: target) {
            case .verified:
                return .clipboardPaste
            case .unverified:
                AppLogger.insertion.info(
                    "Paste was dispatched to \(target.name, privacy: .public) but its editor state is not Accessibility-verifiable"
                )
                return .pasteDispatched
            case .failed:
                AppLogger.insertion.error(
                    "Paste was dispatched to \(target.name, privacy: .public) but no editor change was observed"
                )
                return .automaticInsertionUnverified
            }
        }

        do {
            switch try await directInserter.insertDirectly(text, target: target) {
            case .verified:
                return .accessibility
            case .failed:
                AppLogger.insertion.info("Direct Accessibility insertion was not observed; using keyboard-event fallback")
            case .unverified:
                AppLogger.insertion.error("Direct Accessibility insertion could not be verified")
                return .automaticInsertionUnverified
            }
        } catch {
            AppLogger.insertion.info("Direct Accessibility insertion unavailable; using keyboard-event fallback")
        }

        let keyboardResult = try await keyboardInserter.type(text, target: target)
        switch keyboardResult {
        case .verified:
            return .keyboardEvents
        case .unverified:
            AppLogger.insertion.error("Keyboard-event insertion could not be verified")
            return .automaticInsertionUnverified
        case .failed:
            AppLogger.insertion.info("Keyboard-event insertion was not observed; using paste fallback")
        }

        return try await paste(text, target: target)
    }

    private func paste(_ text: String, target: TargetApplication) async throws -> TextInsertionOutcome {
        let pasteResult = try await pasteInserter.paste(text, target: target)
        switch pasteResult {
        case .verified:
            return .clipboardPaste
        case .failed, .unverified:
            AppLogger.insertion.error("Paste insertion could not be verified")
            return .automaticInsertionUnverified
        }
    }

    func copy(_ text: String) {
        clipboard.writeText(text)
    }
}
