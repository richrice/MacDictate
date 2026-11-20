import AppKit
import Foundation
import SwiftUI

struct LearnedReplacement: Codable, Hashable, Identifiable, Sendable {
    let from: String
    let to: String

    var id: String { "\(from.lowercased())→\(to)" }
}

struct CorrectionSuggestion: Equatable, Sendable {
    let promptHints: [String]
    let replacements: [LearnedReplacement]
}

enum TranscriptPostProcessor {
    /// Applies user-approved, unambiguous phonetic replacement rules in a single pass
    /// (longest match first, Unicode-aware word boundaries) so partial words are never
    /// mangled and rules never chain-rewrite another rule's output.
    static func apply(_ replacements: [LearnedReplacement], to transcript: String) -> String {
        guard !replacements.isEmpty, !transcript.isEmpty else { return transcript }
        let ordered = replacements
            .filter {
                !$0.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.from.count > $1.from.count }
        guard !ordered.isEmpty else { return transcript }

        var lookup: [String: String] = [:]
        var alternatives: [String] = []
        for rule in ordered {
            let key = rule.from.lowercased()
            guard lookup[key] == nil else { continue }
            lookup[key] = rule.to
            alternatives.append(NSRegularExpression.escapedPattern(for: rule.from))
        }

        let pattern = #"(?<![\p{L}\p{N}])(?:\#(alternatives.joined(separator: "|")))(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return transcript
        }

        let nsText = transcript as NSString
        let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return transcript }

        let result = NSMutableString(string: transcript)
        for match in matches.reversed() {
            let matchedText = nsText.substring(with: match.range)
            if let replacement = lookup[matchedText.lowercased()] {
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return result as String
    }

    static func containsWholeToken(_ token: String, in text: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let pattern = #"(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

enum CorrectionAnalysisError: LocalizedError, Equatable {
    case missingAPIKey
    case unchangedText
    case network(String)
    case httpError(status: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an OpenAI API key in Settings first."
        case .unchangedText:
            "Edit the transcription first so there is a change to learn from."
        case let .network(detail):
            "Could not contact OpenAI. \(detail)"
        case let .httpError(status, message):
            "OpenAI returned HTTP \(status). \(message)"
        case .malformedResponse:
            "OpenAI returned an unexpected suggestion format."
        }
    }
}

protocol CorrectionAnalyzing: Sendable {
    func analyze(
        original: String,
        corrected: String,
        existingHints: [String],
        existingReplacements: [LearnedReplacement],
        apiKey: String
    ) async throws -> CorrectionSuggestion
}

struct OpenAICorrectionAnalyzer: CorrectionAnalyzing {
    private static let sharedSession: URLSession = makeSession()

    private let session: URLSession
    private let endpoint: URL
    private let model: String

    init(
        session: URLSession = OpenAICorrectionAnalyzer.sharedSession,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: String = "gpt-4o-mini"
    ) {
        self.session = session
        self.endpoint = endpoint
        self.model = model
    }

    func analyze(
        original: String,
        corrected: String,
        existingHints: [String],
        existingReplacements: [LearnedReplacement],
        apiKey: String
    ) async throws -> CorrectionSuggestion {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCorrected.isEmpty, trimmedOriginal != trimmedCorrected else {
            throw CorrectionAnalysisError.unchangedText
        }

        let request = try makeRequest(
            original: trimmedOriginal,
            corrected: trimmedCorrected,
            existingHints: existingHints,
            existingReplacements: existingReplacements,
            apiKey: apiKey
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CorrectionAnalysisError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CorrectionAnalysisError.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = OpenAITranscriptionService.parseErrorMessage(data)
            throw CorrectionAnalysisError.httpError(status: http.statusCode, message: message)
        }

        return try Self.parseResponse(data, original: trimmedOriginal, corrected: trimmedCorrected)
    }

    func makeRequest(
        original: String,
        corrected: String,
        existingHints: [String],
        existingReplacements: [LearnedReplacement],
        apiKey: String
    ) throws -> URLRequest {
        let systemPrompt = """
            You help a macOS voice-to-text app learn from a user's manual correction of a speech transcription.
            Return ONLY a JSON object with two keys:
            - "promptHints": array of 0-2 very short strings (under 70 characters each) to append to the speech-to-text vocabulary prompt.
              Prefer compact term/disambiguation hints like "TRXLINK (Jira key, distinct from TraxxasLink app)" or "TRXTQI (Jira key)".
              Do not duplicate hints already present.
            - "replacements": array of 0-3 objects {"from": "...", "to": "..."} for deterministic post-transcription replacement.
              CRITICAL SAFETY RULE: NEVER propose a replacement when "from" is a real English word, normal phrase, or real product/app name the user might intentionally say in another sentence (for example, NEVER replace "Traxxas Link" with "TRXLINK" because "Traxxas Link" is a real app name; use a promptHint instead!).
              ONLY propose a replacement when "from" is an unambiguous phonetic artifact or split token that would never be intended literally (for example, "TRX Link" -> "TRXLINK" or "TRX TQi" -> "TRXTQI").
            """

        let existingSummary = """
            Original transcript: \(original)
            Corrected transcript: \(corrected)
            Existing prompt hints: \(existingHints.joined(separator: " | "))
            Existing replacements: \(existingReplacements.map { "\($0.from) -> \($0.to)" }.joined(separator: ", "))
            """

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": existingSummary]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func parseResponse(
        _ data: Data,
        original: String? = nil,
        corrected: String? = nil
    ) throws -> CorrectionSuggestion {
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }

        struct SuggestionPayload: Decodable {
            struct ReplacementItem: Decodable {
                let from: String
                let to: String
            }
            let promptHints: [String]?
            let replacements: [ReplacementItem]?
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw CorrectionAnalysisError.malformedResponse
        }

        guard let content = decoded.choices.first?.message.content,
              let contentData = content.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SuggestionPayload.self, from: contentData) else {
            throw CorrectionAnalysisError.malformedResponse
        }

        let hints = Array((payload.promptHints ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2))

        let replacements = Array((payload.replacements ?? [])
            .map {
                LearnedReplacement(
                    from: $0.from.trimmingCharacters(in: .whitespacesAndNewlines),
                    to: $0.to.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { rule in
                guard !rule.from.isEmpty,
                      !rule.to.isEmpty,
                      rule.from.caseInsensitiveCompare(rule.to) != .orderedSame else {
                    return false
                }
                // Ground every LLM-suggested replacement in the actual edit:
                // `from` must appear in the original, `to` must appear in the corrected text,
                // and `from` must NOT still appear in the corrected text (which means the user kept it).
                if let original, let corrected {
                    guard TranscriptPostProcessor.containsWholeToken(rule.from, in: original),
                          TranscriptPostProcessor.containsWholeToken(rule.to, in: corrected),
                          !TranscriptPostProcessor.containsWholeToken(rule.from, in: corrected) else {
                        return false
                    }
                }
                return true
            }
            .prefix(3))

        return CorrectionSuggestion(promptHints: hints, replacements: replacements)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class CorrectionViewModel: ObservableObject {
    struct SelectableHint: Identifiable {
        let id = UUID()
        let text: String
        var isSelected: Bool
    }

    struct SelectableReplacement: Identifiable {
        let id = UUID()
        let rule: LearnedReplacement
        var isSelected: Bool
    }

    let entries: [String]
    @Published var selectedIndex: Int = 0 {
        didSet { resetForSelectedEntry() }
    }
    @Published var correctedText: String {
        didSet {
            if hasAnalyzed, correctedText != lastAnalyzedText {
                hasAnalyzed = false
                suggestedHints = []
                suggestedReplacements = []
            }
        }
    }
    @Published private(set) var isAnalyzing = false
    @Published private(set) var hasAnalyzed = false
    @Published var suggestedHints: [SelectableHint] = []
    @Published var suggestedReplacements: [SelectableReplacement] = []
    @Published private(set) var errorMessage: String?

    private let settings: SettingsStore
    private let credentialStore: SecureCredentialStore
    private let analyzer: CorrectionAnalyzing
    private let onApplyCorrected: (Int, String) -> Void
    private let onDismiss: () -> Void
    private var analysisTask: Task<Void, Never>?
    private var lastAnalyzedText: String?

    var originalText: String {
        guard entries.indices.contains(selectedIndex) else { return "" }
        return entries[selectedIndex]
    }

    var hasEdits: Bool {
        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        entries: [String],
        settings: SettingsStore,
        credentialStore: SecureCredentialStore,
        analyzer: CorrectionAnalyzing = OpenAICorrectionAnalyzer(),
        onApplyCorrected: @escaping (Int, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.correctedText = entries.first ?? ""
        self.settings = settings
        self.credentialStore = credentialStore
        self.analyzer = analyzer
        self.onApplyCorrected = onApplyCorrected
        self.onDismiss = onDismiss
    }

    private func resetForSelectedEntry() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        hasAnalyzed = false
        lastAnalyzedText = nil
        suggestedHints = []
        suggestedReplacements = []
        errorMessage = nil
        correctedText = originalText
    }

    func analyze() {
        guard !isAnalyzing else { return }
        guard hasEdits else {
            errorMessage = CorrectionAnalysisError.unchangedText.localizedDescription
            return
        }
        guard let apiKey = try? credentialStore.load(), !apiKey.isEmpty else {
            errorMessage = CorrectionAnalysisError.missingAPIKey.localizedDescription
            return
        }

        isAnalyzing = true
        errorMessage = nil
        let original = originalText
        let corrected = correctedText
        let existingHints = settings.learnedPromptHints
        let existingReplacements = settings.learnedReplacements
        let analyzer = self.analyzer

        analysisTask = Task { [weak self] in
            do {
                let suggestion = try await analyzer.analyze(
                    original: original,
                    corrected: corrected,
                    existingHints: existingHints,
                    existingReplacements: existingReplacements,
                    apiKey: apiKey
                )
                guard !Task.isCancelled, let self else { return }
                self.suggestedHints = suggestion.promptHints.map {
                    SelectableHint(text: $0, isSelected: true)
                }
                // Replacements default to unchecked so the user explicitly opts in
                // to any deterministic post-transcription rewrite.
                self.suggestedReplacements = suggestion.replacements.map {
                    SelectableReplacement(rule: $0, isSelected: false)
                }
                self.lastAnalyzedText = corrected
                self.hasAnalyzed = true
                self.isAnalyzing = false
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.isAnalyzing = false
            }
        }
    }

    func copyOnly() {
        let finalText = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            onApplyCorrected(selectedIndex, finalText)
        }
        cancel()
    }

    func applySelectedAndCopy() {
        for hint in suggestedHints where hint.isSelected {
            settings.addLearnedPromptHint(hint.text)
        }
        for item in suggestedReplacements where item.isSelected {
            settings.addLearnedReplacement(item.rule)
        }
        let finalText = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            onApplyCorrected(selectedIndex, finalText)
        }
        cancel()
    }

    func cancel() {
        analysisTask?.cancel()
        analysisTask = nil
        onDismiss()
    }
}

struct CorrectionView: View {
    @ObservedObject var viewModel: CorrectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Correct Transcription")
                    .font(.title3.weight(.semibold))
                Text("Fix what was misheard, then let OpenAI suggest prompt hints so future dictations improve without hijacking valid words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.entries.count > 1 {
                Picker("Recent transcription", selection: $viewModel.selectedIndex) {
                    ForEach(Array(viewModel.entries.enumerated()), id: \.offset) { index, entry in
                        Text("\(index + 1). \(entry.prefix(64))").tag(index)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Original")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(viewModel.originalText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Corrected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.correctedText)
                    .font(.body)
                    .frame(minHeight: 72, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if viewModel.hasAnalyzed {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested Learning")
                        .font(.subheadline.weight(.semibold))

                    if viewModel.suggestedHints.isEmpty && viewModel.suggestedReplacements.isEmpty {
                        Text("No reusable vocabulary updates were suggested for this edit. You can still copy the corrected text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        if !viewModel.suggestedHints.isEmpty {
                            Text("Prompt hints (safe for ambiguous terms):")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach($viewModel.suggestedHints) { $hint in
                                Toggle(hint.text, isOn: $hint.isSelected)
                                    .font(.callout)
                            }
                        }

                        if !viewModel.suggestedReplacements.isEmpty {
                            Text("Optional auto-replacements (unchecked by default — enable only for unambiguous mishearings):")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach($viewModel.suggestedReplacements) { $item in
                                Toggle("“\(item.rule.from)” → “\(item.rule.to)”", isOn: $item.isSelected)
                                    .font(.callout)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Cancel") { viewModel.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if viewModel.hasAnalyzed {
                    Button("Re-analyze") { viewModel.analyze() }
                        .disabled(!viewModel.hasEdits || viewModel.isAnalyzing)
                    Button("Save Selected & Copy") { viewModel.applySelectedAndCopy() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Copy Only") { viewModel.copyOnly() }
                        .disabled(viewModel.correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(viewModel.isAnalyzing ? "Analyzing…" : "Suggest Updates") {
                        viewModel.analyze()
                    }
                    .disabled(!viewModel.hasEdits || viewModel.isAnalyzing)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

@MainActor
final class CorrectionWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void
    private var didClose = false

    init(viewModel: CorrectionViewModel, onClose: @escaping () -> Void) {
        let hostingController = NSHostingController(rootView: CorrectionView(viewModel: viewModel))
        window = NSWindow(contentViewController: hostingController)
        window.title = "Correct Transcription"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.onClose = onClose
        super.init()
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard !didClose else { return }
        didClose = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        onClose()
    }
}
