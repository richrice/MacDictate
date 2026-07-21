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
    func insertDirectly(_ text: String, target: TargetApplication) throws {
        calls += 1
        if let error { throw error }
    }
}

@MainActor
private final class MockPasteInserter: PasteTextInserting {
    var calls = 0
    func paste(_ text: String, target: TargetApplication) async throws { calls += 1 }
}

@MainActor
private final class MockClipboard: ClipboardManaging {
    var text: String?
    var changeCount = 0
    func snapshot() -> ClipboardSnapshot { ClipboardSnapshot(items: []) }
    func writeText(_ text: String) -> Int { self.text = text; changeCount += 1; return changeCount }
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

    func testTextInsertionFallbackOrder() async throws {
        let permission = MockAccessibilityPermission()
        let direct = MockDirectInserter()
        direct.error = TextInsertionError.accessibilityRejected("unsupported")
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
            pasteInserter: paste,
            clipboard: clipboard
        )
        let target = TargetApplication(processIdentifier: 1, bundleIdentifier: nil, name: "Test")

        let outcome = try await service.insert("hello", target: target)
        XCTAssertEqual(outcome, .clipboardPaste)
        XCTAssertEqual(direct.calls, 1)
        XCTAssertEqual(paste.calls, 1)
    }

    func testMissingAccessibilityPermissionCopiesOnly() async throws {
        let permission = MockAccessibilityPermission()
        permission.allowed = false
        let direct = MockDirectInserter()
        let paste = MockPasteInserter()
        let clipboard = MockClipboard()
        let service = DefaultTextInsertionService(
            permissionManager: permission,
            directInserter: direct,
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
}

