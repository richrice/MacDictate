import AppKit
import XCTest
@testable import MacDictate

final class InMemoryCredentialStore: SecureCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func load() throws -> String? { lock.withLock { value } }
    func save(_ credential: String) throws { lock.withLock { value = credential } }
    func delete() throws { lock.withLock { value = nil } }
}

@MainActor
private final class MockAccessibilityPermission: AccessibilityPermissionProviding {
    var allowed = true
    func requestIfNeeded() -> Bool { allowed }
}

@MainActor
private final class MockDirectInserter: DirectTextInserting {
    var calls = 0
    var error: Error?
    var result: EventTextInsertionResult = .verified

    func insertDirectly(
        _ text: String,
        target: TargetApplication
    ) async throws -> EventTextInsertionResult {
        calls += 1
        if let error { throw error }
        return result
    }
}

@MainActor
private final class MockKeyboardInserter: KeyboardTextInserting {
    var calls = 0
    var result: EventTextInsertionResult = .verified

    func type(_ text: String, target: TargetApplication) async throws -> EventTextInsertionResult {
        calls += 1
        return result
    }
}

@MainActor
private final class MockPasteInserter: PasteTextInserting {
    var calls = 0
    var result: EventTextInsertionResult = .verified

    func paste(_ text: String, target: TargetApplication) async throws -> EventTextInsertionResult {
        calls += 1
        return result
    }
}

@MainActor
private final class MockClipboard: ClipboardManaging {
    var text: String?
    var changeCount = 0
    func snapshot() -> ClipboardSnapshot { ClipboardSnapshot(items: []) }
    func writeText(_ text: String, transient: Bool) -> Int { self.text = text; changeCount += 1; return changeCount }
    func restore(_ snapshot: ClipboardSnapshot, ifChangeCountIs expectedChangeCount: Int) -> Bool { true }
}

@MainActor
final class StorageInsertionAndPrivacyTests: XCTestCase {
    func testKeychainProtocolBehaviorWithInMemoryMock() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.load())
        try store.save("first")
        XCTAssertEqual(try store.load(), "first")
        try store.save("replacement")
        XCTAssertEqual(try store.load(), "replacement")
        try store.delete()
        XCTAssertNil(try store.load())
        try store.delete()
    }

    func testClipboardRestoresWhenUnchanged() {
        let pasteboard = NSPasteboard(name: .init("MacDictateTests-\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let manager = ClipboardManager(pasteboard: pasteboard)
        let snapshot = manager.snapshot()
        let expected = manager.writeText("transcript")

        XCTAssertTrue(manager.restore(snapshot, ifChangeCountIs: expected))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testClipboardDoesNotRestoreAfterExternalChange() {
        let pasteboard = NSPasteboard(name: .init("MacDictateTests-\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let manager = ClipboardManager(pasteboard: pasteboard)
        let snapshot = manager.snapshot()
        let expected = manager.writeText("transcript")
        pasteboard.clearContents()
        pasteboard.setString("newer user value", forType: .string)

        XCTAssertFalse(manager.restore(snapshot, ifChangeCountIs: expected))
        XCTAssertEqual(pasteboard.string(forType: .string), "newer user value")
    }

    func testTransientWritesCarryClipboardManagerMarker() {
        let pasteboard = NSPasteboard(name: .init("MacDictateTests-\(UUID())"))
        let manager = ClipboardManager(pasteboard: pasteboard)

        manager.writeText("temporary transcript", transient: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "temporary transcript")
        XCTAssertNotNil(pasteboard.data(forType: ClipboardManager.transientType))

        manager.writeText("kept transcript")
        XCTAssertEqual(pasteboard.string(forType: .string), "kept transcript")
        XCTAssertNil(pasteboard.data(forType: ClipboardManager.transientType))
    }

    func testTextInsertionFallbackOrder() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        direct.error = TextInsertionError.accessibilityRejected("unsupported")
        let keyboard = MockKeyboardInserter()
        keyboard.result = .failed
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )
        let target = TargetApplication(processIdentifier: 1, bundleIdentifier: nil, name: "Test")

        let outcome = try await service.insert("hello", target: target)
        XCTAssertEqual(outcome, .clipboardPaste)
        XCTAssertEqual(direct.calls, 1)
        XCTAssertEqual(keyboard.calls, 1)
        XCTAssertEqual(paste.calls, 1)
    }

    func testVerifiedKeyboardInsertionSkipsPasteFallback() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        direct.error = TextInsertionError.accessibilityRejected("unsupported")
        let keyboard = MockKeyboardInserter()
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "hello",
            target: TargetApplication(processIdentifier: 1, bundleIdentifier: nil, name: "Test")
        )

        XCTAssertEqual(outcome, .keyboardEvents)
        XCTAssertEqual(keyboard.calls, 1)
        XCTAssertEqual(paste.calls, 0)
        XCTAssertNil(clipboard.text)
    }

    func testUnverifiedDirectInsertionStopsBeforeRiskingDuplicateEvents() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        direct.result = .unverified
        let keyboard = MockKeyboardInserter()
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "keep me",
            target: TargetApplication(processIdentifier: 1, bundleIdentifier: nil, name: "Test")
        )

        XCTAssertEqual(outcome, .automaticInsertionUnverified)
        XCTAssertEqual(keyboard.calls, 0)
        XCTAssertEqual(paste.calls, 0)
        XCTAssertNil(clipboard.text)
    }

    func testUnverifiedKeyboardInsertionDoesNotRiskDuplicatePaste() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        direct.error = TextInsertionError.accessibilityRejected("unsupported")
        let keyboard = MockKeyboardInserter()
        keyboard.result = .unverified
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "keep me",
            target: TargetApplication(processIdentifier: 1, bundleIdentifier: nil, name: "Test")
        )

        XCTAssertEqual(outcome, .automaticInsertionUnverified)
        XCTAssertEqual(paste.calls, 0, "An unverified keyboard attempt may have succeeded; pasting could duplicate it")
        XCTAssertNil(clipboard.text)
    }

    func testUnverifiedPasteIsNotReportedAsSuccessful() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        direct.error = TextInsertionError.accessibilityRejected("unsupported")
        let keyboard = MockKeyboardInserter()
        keyboard.result = .failed
        let paste = MockPasteInserter()
        paste.result = .unverified
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "manual fallback",
            target: TargetApplication(processIdentifier: 1, bundleIdentifier: nil, name: "Test")
        )

        XCTAssertEqual(outcome, .automaticInsertionUnverified)
        XCTAssertEqual(paste.calls, 1)
        XCTAssertNil(clipboard.text)
    }

    func testCodexUsesProvenPasteRouteWithoutTryingAXOrUnicodeEvents() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        let keyboard = MockKeyboardInserter()
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "hello Codex",
            target: TargetApplication(
                processIdentifier: 1,
                bundleIdentifier: "com.openai.codex",
                name: "ChatGPT"
            )
        )

        XCTAssertEqual(outcome, .clipboardPaste)
        XCTAssertEqual(direct.calls, 0)
        XCTAssertEqual(keyboard.calls, 0)
        XCTAssertEqual(paste.calls, 1)
        XCTAssertNil(clipboard.text)
    }

    func testUnverifiableCodexPasteIsReportedAsDispatched() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        let keyboard = MockKeyboardInserter()
        let paste = MockPasteInserter()
        paste.result = .unverified
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "hello Codex",
            target: TargetApplication(
                processIdentifier: 1,
                bundleIdentifier: "com.openai.codex",
                name: "ChatGPT"
            )
        )

        XCTAssertEqual(outcome, .pasteDispatched)
        XCTAssertEqual(direct.calls, 0)
        XCTAssertEqual(keyboard.calls, 0)
        XCTAssertEqual(paste.calls, 1)
        XCTAssertNil(clipboard.text)
    }

    func testUnverifiableITermPasteIsReportedAsDispatched() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        let keyboard = MockKeyboardInserter()
        let paste = MockPasteInserter()
        paste.result = .unverified
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "hello iTerm2",
            target: TargetApplication(
                processIdentifier: 1,
                bundleIdentifier: "com.googlecode.iterm2",
                name: "iTerm2"
            )
        )

        XCTAssertEqual(outcome, .pasteDispatched)
        XCTAssertEqual(direct.calls, 0)
        XCTAssertEqual(keyboard.calls, 0)
        XCTAssertEqual(paste.calls, 1)
        XCTAssertNil(clipboard.text)
    }

    func testITermPasteUsesFrontmostHIDEvents() {
        XCTAssertTrue(
            ClipboardPasteInserter.requiresFrontmostHIDEvents(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
        XCTAssertTrue(
            ClipboardPasteInserter.requiresFrontmostHIDEvents(
                bundleIdentifier: "com.openai.codex"
            )
        )
        XCTAssertFalse(
            ClipboardPasteInserter.requiresFrontmostHIDEvents(
                bundleIdentifier: "com.apple.Terminal"
            )
        )
    }

    func testCanonicalOutputStateRestoresCurrentRouteLast() {
        XCTAssertEqual(
            SystemAudioOutputController.restorationTargets(
                originalDeviceID: 11,
                currentDeviceID: 22
            ),
            [11, 22]
        )
        XCTAssertEqual(
            SystemAudioOutputController.restorationTargets(
                originalDeviceID: 11,
                currentDeviceID: 11
            ),
            [11]
        )
    }

    func testUnicodeEventChunksPreserveCharactersAndRespectNormalLimit() {
        let text = "1234567890123456789é👩🏽‍💻tail"
        let chunks = UnicodeKeyboardTextInserter.chunks(text, maximumUTF16Length: 20)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 })
    }

    func testMissingAccessibilityPermissionCopiesOnly() async throws {
        let permission = MockAccessibilityPermission()
        permission.allowed = false
        let direct = MockDirectInserter()
        let keyboard = MockKeyboardInserter()
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            keyboardInserter: keyboard,
            pasteInserter: paste,
            clipboard: clipboard
        )
        let outcome = try await service.insert(
            "manual paste",
            target: TargetApplication(processIdentifier: 1, bundleIdentifier: nil, name: "Test")
        )

        XCTAssertEqual(outcome, .copiedForManualPaste)
        XCTAssertEqual(clipboard.text, "manual paste")
        XCTAssertEqual(direct.calls, 0)
        XCTAssertEqual(keyboard.calls, 0)
        XCTAssertEqual(paste.calls, 0)
    }

    func testTemporaryFilesDeletedForEveryTerminalOutcome() throws {
        let cleaner = TemporaryFileCleaner()
        for outcome in ["success", "cancellation", "failure"] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacDictate-\(outcome)-\(UUID())")
            try Data("audio".utf8).write(to: file)
            cleaner.delete(file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testAPIKeyAndAuthorizationAreRedactedFromDiagnostics() {
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz"
        let source = "api_key=\(key) Authorization: Bearer \(key)"
        let redacted = SecretRedactor.redact(source)
        XCTAssertFalse(redacted.contains(key))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    func testBareKeyAndBareBearerTokenAreRedacted() {
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz"
        XCTAssertFalse(SecretRedactor.redact("error mentioning \(key) alone").contains(key))

        let bearer = "Bearer some.opaque-token+value"
        XCTAssertFalse(SecretRedactor.redact("header was \(bearer)").contains("some.opaque-token+value"))
    }
}
