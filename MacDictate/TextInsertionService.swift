import AppKit
import ApplicationServices
import Foundation

struct TargetApplication: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
}

enum TextInsertionOutcome: Equatable, Sendable {
    case accessibility
    case clipboardPaste
    case copiedForManualPaste
}

enum TextInsertionError: LocalizedError, Equatable {
    case targetUnavailable
    case accessibilityRejected(String)
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .targetUnavailable: "The application that was focused when recording began is no longer available."
        case let .accessibilityRejected(detail): "The target application rejected text insertion. \(detail)"
        case .eventCreationFailed: "macOS could not create the paste keyboard event."
        }
    }
}

@MainActor
protocol DirectTextInserting: AnyObject {
    func insertDirectly(_ text: String, target: TargetApplication) throws
}

@MainActor
protocol PasteTextInserting: AnyObject {
    func paste(_ text: String, target: TargetApplication) async throws
}

@MainActor
protocol TextInsertionService: AnyObject {
    func insert(_ text: String, target: TargetApplication) async throws -> TextInsertionOutcome
    func copy(_ text: String)
}

@MainActor
final class AccessibilityDirectInserter: DirectTextInserting {
    func insertDirectly(_ text: String, target: TargetApplication) throws {
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
            let candidate = unsafeDowncast(currentFocusedValue, to: AXUIElement.self)
            var focusedPID = pid_t()
            if AXUIElementGetPid(candidate, &focusedPID) != .success || focusedPID != target.processIdentifier {
                // Activation is asynchronous; never insert into a different app's focused control.
                focusedValue = nil
                result = .cannotComplete
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

        guard result == .success, let focusedValue else {
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
        let insertionResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard insertionResult == .success else {
            throw TextInsertionError.accessibilityRejected("AX error \(insertionResult.rawValue).")
        }
    }
}

@MainActor
final class ClipboardPasteInserter: PasteTextInserting {
    private let clipboard: ClipboardManaging
    private let pasteDelayNanoseconds: UInt64

    init(clipboard: ClipboardManaging, pasteDelayNanoseconds: UInt64 = 350_000_000) {
        self.clipboard = clipboard
        self.pasteDelayNanoseconds = pasteDelayNanoseconds
    }

    func paste(_ text: String, target: TargetApplication) async throws {
        guard let runningApplication = NSRunningApplication(processIdentifier: target.processIdentifier),
              !runningApplication.isTerminated else {
            throw TextInsertionError.targetUnavailable
        }
        let snapshot = clipboard.snapshot()
        let transcriptChangeCount = clipboard.writeText(text)
        do {
            if !runningApplication.isActive {
                runningApplication.activate(options: [])
                try await Task.sleep(for: .milliseconds(120))
            }

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
                throw TextInsertionError.eventCreationFailed
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            try await Task.sleep(nanoseconds: pasteDelayNanoseconds)
            _ = clipboard.restore(snapshot, ifChangeCountIs: transcriptChangeCount)
        } catch {
            _ = clipboard.restore(snapshot, ifChangeCountIs: transcriptChangeCount)
            throw error
        }
    }
}

@MainActor
final class DefaultTextInsertionService: TextInsertionService {
    private let permissionManager: AccessibilityPermissionProviding
    private let directInserter: DirectTextInserting
    private let pasteInserter: PasteTextInserting
    private let clipboard: ClipboardManaging

    init(
        permissionManager: AccessibilityPermissionProviding,
        directInserter: DirectTextInserting,
        pasteInserter: PasteTextInserting,
        clipboard: ClipboardManaging
    ) {
        self.permissionManager = permissionManager
        self.directInserter = directInserter
        self.pasteInserter = pasteInserter
        self.clipboard = clipboard
    }

    func insert(_ text: String, target: TargetApplication) async throws -> TextInsertionOutcome {
        guard permissionManager.requestIfNeeded() else {
            clipboard.writeText(text)
            return .copiedForManualPaste
        }
        do {
            try directInserter.insertDirectly(text, target: target)
            return .accessibility
        } catch {
            AppLogger.insertion.info("Direct Accessibility insertion unavailable; using paste fallback")
            try await pasteInserter.paste(text, target: target)
            return .clipboardPaste
        }
    }

    func copy(_ text: String) {
        clipboard.writeText(text)
    }
}
