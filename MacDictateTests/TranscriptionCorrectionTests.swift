import Foundation
import XCTest
@testable import MacDictate

private struct MockCorrectionAnalyzer: CorrectionAnalyzing {
    let suggestion: CorrectionSuggestion

    func analyze(
        original: String,
        corrected: String,
        existingHints: [String],
        existingReplacements: [LearnedReplacement],
        apiKey: String
    ) async throws -> CorrectionSuggestion {
        suggestion
    }
}

final class TranscriptionCorrectionTests: XCTestCase {
    func testPostProcessorAppliesWordBoundaryReplacementsCaseInsensitively() {
        let rules = [
            LearnedReplacement(from: "TRX Link", to: "TRXLINK"),
            LearnedReplacement(from: "TRX TQi", to: "TRXTQI")
        ]

        let output = TranscriptPostProcessor.apply(
            rules,
            to: "What do you think of the last trx link issue and the last TRX TQi issue?"
        )

        XCTAssertEqual(
            output,
            "What do you think of the last TRXLINK issue and the last TRXTQI issue?"
        )
    }

    func testPostProcessorDoesNotMangleSubstringsInsideOtherWords() {
        let rules = [LearnedReplacement(from: "link", to: "LINK")]
        let output = TranscriptPostProcessor.apply(rules, to: "Open TraxxasLink and link it")
        XCTAssertEqual(output, "Open TraxxasLink and LINK it")
    }

    func testPostProcessorAppliesSinglePassWithoutRuleChaining() {
        let rules = [
            LearnedReplacement(from: "foo", to: "bar"),
            LearnedReplacement(from: "bar", to: "baz")
        ]
        let output = TranscriptPostProcessor.apply(rules, to: "foo and bar")
        XCTAssertEqual(output, "bar and baz")
    }

    func testParseOpenAICorrectionResponseValidatesAndCapsSuggestions() throws {
        let contentJSON = #"{"promptHints":["Hint 1","Hint 2","Hint 3 overflow"],"replacements":[{"from":"TRX Link","to":"TRXLINK"},{"from":"Traxxas Link","to":"TRXLINK"},{"from":"hallucinated","to":"TRXLINK"},{"from":"same","to":"SAME"}]}"#
        let envelope: [String: Any] = [
            "choices": [
                ["message": ["content": contentJSON]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        // Original has both "Traxxas Link" (kept in corrected) and "TRX Link" (replaced with "TRXLINK").
        let suggestion = try OpenAICorrectionAnalyzer.parseResponse(
            data,
            original: "Open Traxxas Link and check TRX Link",
            corrected: "Open Traxxas Link and check TRXLINK"
        )

        XCTAssertEqual(suggestion.promptHints, ["Hint 1", "Hint 2"])
        XCTAssertEqual(
            suggestion.replacements,
            [LearnedReplacement(from: "TRX Link", to: "TRXLINK")]
        )
    }

    @MainActor
    func testCorrectionViewModelDefaultsHintsSelectedAndClearsStaleSuggestionsOnEdit() async throws {
        let suiteName = "CorrectionVMTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let credentials = InMemoryCredentialStore()
        try credentials.save("sk-test-key")

        let analyzer = MockCorrectionAnalyzer(
            suggestion: CorrectionSuggestion(
                promptHints: ["TRXLINK (Jira key)"],
                replacements: [LearnedReplacement(from: "TRX Link", to: "TRXLINK")]
            )
        )
        var appliedResult: (Int, String)?
        var didDismiss = false

        let viewModel = CorrectionViewModel(
            entries: ["Check the TRX Link issue"],
            settings: settings,
            credentialStore: credentials,
            analyzer: analyzer,
            onApplyCorrected: { index, text in appliedResult = (index, text) },
            onDismiss: { didDismiss = true }
        )

        viewModel.correctedText = "Check the TRXLINK issue"
        viewModel.analyze()

        let deadline = Date().addingTimeInterval(2)
        while !viewModel.hasAnalyzed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(viewModel.hasAnalyzed)
        XCTAssertEqual(viewModel.suggestedHints.first?.isSelected, true)
        XCTAssertEqual(viewModel.suggestedReplacements.first?.isSelected, false)

        // Editing text after analysis clears stale suggestions.
        viewModel.correctedText = "Check the TRXLINK-123 issue"
        XCTAssertFalse(viewModel.hasAnalyzed)
        XCTAssertTrue(viewModel.suggestedHints.isEmpty)

        // Re-analyze and save with defaults.
        viewModel.analyze()
        let deadline2 = Date().addingTimeInterval(2)
        while !viewModel.hasAnalyzed, Date() < deadline2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        viewModel.applySelectedAndCopy()

        XCTAssertEqual(settings.learnedPromptHints, ["TRXLINK (Jira key)"])
        XCTAssertTrue(settings.learnedReplacements.isEmpty)
        XCTAssertEqual(appliedResult?.0, 0)
        XCTAssertEqual(appliedResult?.1, "Check the TRXLINK-123 issue")
        XCTAssertTrue(didDismiss)
    }

    @MainActor
    func testCorrectionViewModelCopyOnlyWorksWithoutAPI() throws {
        let suiteName = "CorrectionCopyOnlyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        var appliedResult: (Int, String)?
        let viewModel = CorrectionViewModel(
            entries: ["Check TRX Link"],
            settings: settings,
            credentialStore: InMemoryCredentialStore(),
            onApplyCorrected: { index, text in appliedResult = (index, text) },
            onDismiss: {}
        )
        viewModel.correctedText = "Check TRXLINK"
        viewModel.copyOnly()

        XCTAssertEqual(appliedResult?.0, 0)
        XCTAssertEqual(appliedResult?.1, "Check TRXLINK")
    }

    @MainActor
    func testSettingsStorePersistsLearnedHintsAndReplacements() throws {
        let suiteName = "LearnedSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var store: SettingsStore? = SettingsStore(defaults: defaults)
        store?.addLearnedPromptHint("Use TRXLINK for Jira keys")
        store?.addLearnedPromptHint("use trxlink for jira keys") // duplicate ignored
        store?.addLearnedReplacement(LearnedReplacement(from: "TRX Link", to: "TRXLINK"))
        store = nil

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.learnedPromptHints, ["Use TRXLINK for Jira keys"])
        XCTAssertEqual(
            reloaded.learnedReplacements,
            [LearnedReplacement(from: "TRX Link", to: "TRXLINK")]
        )

        let prompt = DictationContextComposer.composePrompt(
            basePrompt: "Base.",
            learnedHints: reloaded.learnedPromptHints,
            context: nil
        )
        XCTAssertTrue(prompt.contains("Learned vocabulary hints: Use TRXLINK for Jira keys."))
    }
}
