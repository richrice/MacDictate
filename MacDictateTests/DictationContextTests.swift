import Foundation
import XCTest
@testable import MacDictate

final class DictationContextTests: XCTestCase {
    func testExtractsJiraIssueKeysAndProjectPrefixesWhileIgnoringTechnicalTokens() {
        let sources = [
            "feature/TRXLINK-1420-ble-reconnect",
            "Fix UTF-8 encoding and SHA-256 hash in TRXLINK-1418",
            "Verify ESP-32 and GPT-4 behavior for PROJ-99"
        ]

        let keys = DictationContextComposer.extractIssueKeys(from: sources, limit: 4)

        XCTAssertEqual(keys, ["TRXLINK", "PROJ", "TRXLINK-1420", "TRXLINK-1418"])
    }

    func testComposePromptCombinesBasePromptWithWindowGitAndCursorContext() {
        let snapshot = DictationContextSnapshot(
            appName: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            windowTitle: "TraxxasLink — claude",
            documentPath: "/Users/rich/Traxxas/TraxxasLink",
            precedingText: nil,
            recentTranscription: "Look at TRXLINK-1420 for the disconnect issue.",
            gitContext: GitRepositoryContext(
                repositoryName: "TraxxasLink",
                branchName: "feature/TRXLINK-1420-reconnect",
                issueKeys: ["TRXLINK", "TRXLINK-1420"],
                activeFileNames: ["BLEManager.swift", "DashboardViewController.swift"]
            )
        )

        let prompt = DictationContextComposer.composePrompt(
            basePrompt: "Base engineering prompt.",
            context: snapshot
        )

        XCTAssertTrue(prompt.hasPrefix("Base engineering prompt.\n\nCurrent context: "))
        XCTAssertTrue(prompt.contains("App: iTerm2"))
        XCTAssertTrue(prompt.contains("Repo: TraxxasLink (branch: feature/TRXLINK-1420-reconnect)"))
        XCTAssertTrue(prompt.contains("TRXLINK, TRXLINK-1420"))
        XCTAssertTrue(prompt.contains("Active files: BLEManager.swift, DashboardViewController.swift"))
        XCTAssertTrue(prompt.contains("Recent dictation: \"Look at TRXLINK-1420"))
    }

    func testComposePromptRedactsSecretsInDynamicContext() {
        let snapshot = DictationContextSnapshot(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "API Notes",
            documentPath: nil,
            precedingText: "Use Bearer sk-proj-supersecret1234567890 here",
            recentTranscription: nil,
            gitContext: nil
        )

        let prompt = DictationContextComposer.composePrompt(basePrompt: "", context: snapshot)

        XCTAssertFalse(prompt.contains("sk-proj-supersecret1234567890"))
        XCTAssertTrue(prompt.contains("<redacted>"))
    }

    func testExtractPrecedingTextSlicesBeforeCaretAndNormalizesWhitespace() {
        let value = "First paragraph.\n\nHi Sarah, following up on TRXLINK-42 regarding the "
        let result = DictationContextComposer.extractPrecedingText(
            value: value,
            selectedLocation: value.utf16.count,
            maxLength: 45
        )

        XCTAssertEqual(result, "following up on TRXLINK-42 regarding the")
    }

    func testExtractDirectoryPathResolvesFileURLAndTildePathsInWindowTitle() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDictateContextPathTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("Sample.swift")
        try Data("let x = 1".utf8).write(to: fileURL)

        let fromDoc = DictationContextComposer.extractDirectoryPath(
            documentAttribute: fileURL.absoluteString,
            windowTitle: nil
        )
        XCTAssertEqual(fromDoc, tempDir.path)

        let fromTitle = DictationContextComposer.extractDirectoryPath(
            documentAttribute: nil,
            windowTitle: "claude — \(tempDir.path)"
        )
        XCTAssertEqual(fromTitle, tempDir.path)
    }

    func testGitRepositoryContextCollectorReadsBranchCommitKeysAndDirtyFiles() async throws {
        let repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDictateGitContextTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = repoDir
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
        }

        try git(["init", "-b", "feature/TRXLINK-777-bluetooth"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test User"])
        try Data("struct App {}".utf8).write(to: repoDir.appendingPathComponent("TraxxasLinkApp.swift"))
        try git(["add", "TraxxasLinkApp.swift"])
        try git(["commit", "-m", "TRXLINK-777 Initial Bluetooth setup"])
        try Data("// dirty".utf8).write(to: repoDir.appendingPathComponent("TelemetryController.swift"))

        let collector = GitRepositoryContextCollector()
        let context = await collector.collect(forDirectory: repoDir.path)

        let unwrapped = try XCTUnwrap(context)
        XCTAssertEqual(unwrapped.repositoryName, repoDir.lastPathComponent)
        XCTAssertEqual(unwrapped.branchName, "feature/TRXLINK-777-bluetooth")
        XCTAssertTrue(unwrapped.issueKeys.contains("TRXLINK"))
        XCTAssertTrue(unwrapped.issueKeys.contains("TRXLINK-777"))
        XCTAssertTrue(unwrapped.activeFileNames.contains("TelemetryController.swift"))
    }

    func testSVNWorkingCopyExtractsIssueKeysFromProjectDocs() async throws {
        let svnDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraxxasLinkSVNTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: svnDir.appendingPathComponent(".svn"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: svnDir) }

        try Data("Commits: Include JIRA ticket IDs (e.g., [TRXLINK-1234] Description).".utf8)
            .write(to: svnDir.appendingPathComponent("GEMINI.md"))

        let collector = GitRepositoryContextCollector()
        let context = await collector.collect(forDirectory: svnDir.path)

        let unwrapped = try XCTUnwrap(context)
        XCTAssertEqual(unwrapped.repositoryName, svnDir.lastPathComponent)
        XCTAssertTrue(unwrapped.issueKeys.contains("TRXLINK"))
        XCTAssertTrue(unwrapped.issueKeys.contains("TRXLINK-1234"))
    }

    func testTerminalTailExtractsIssueKeysWithoutLeakingRawTerminalOutput() {
        let snapshot = DictationContextSnapshot(
            appName: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            windowTitle: "agy",
            documentPath: nil,
            precedingText: nil,
            terminalTail: "secret prompt output referencing TRXLINK-1842 in TraxxasLinkTrunk",
            recentTranscription: nil,
            gitContext: nil
        )

        let prompt = DictationContextComposer.composePrompt(basePrompt: "Base.", context: snapshot)

        XCTAssertTrue(prompt.contains("TRXLINK, TRXLINK-1842"))
        XCTAssertFalse(prompt.contains("secret prompt output"))
    }

    func testDirectChildPIDsReturnsSpawnedChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let children = ProcessWorkingDirectoryLookup.directChildPIDs(of: getpid())
        XCTAssertTrue(
            children.contains(child.processIdentifier),
            "Expected directChildPIDs to include spawned child PID \(child.processIdentifier), got \(children)"
        )
    }

    func testFormatLearnedHintsPreservesWholeHintsWithinBudget() {
        let hints = (1...12).map { "TERM\($0) (Jira key for project \($0))" }
        let formatted = DictationContextComposer.formatLearnedHints(hints, maxLength: 200)
        XCTAssertNotNil(formatted)
        XCTAssertLessThanOrEqual(formatted?.count ?? 0, 200)
        XCTAssertFalse(formatted?.hasSuffix("…") ?? true, "Hints should drop whole items instead of truncating mid-word")
    }

    func testSecretRedactorCatchesCommonTokenFormats() {
        let samples = [
            "ghp_1234567890abcdefghij1234567890",
            "AKIAIOSFODNN7EXAMPLE",
            "xoxb-1234567890-abcdefghij",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "password=supersecretvalue"
        ]
        for sample in samples {
            let redacted = SecretRedactor.redact("value \(sample) end")
            XCTAssertTrue(redacted.contains("<redacted>"), "Failed to redact: \(sample)")
            XCTAssertFalse(redacted.contains("supersecretvalue"))
            XCTAssertFalse(redacted.contains("AKIAIOSFODNN7EXAMPLE"))
        }
    }
}
