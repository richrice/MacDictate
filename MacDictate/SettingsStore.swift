import Carbon.HIToolbox
import Foundation

enum TranscriptionModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case mini = "gpt-4o-mini-transcribe"
    case full = "gpt-4o-transcribe"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .mini: "GPT-4o Mini Transcribe"
        case .full: "GPT-4o Transcribe"
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case english

    var id: String { rawValue }
    var displayName: String { self == .english ? "English" : "Automatic" }
    var apiValue: String? { self == .english ? "en" : nil }
}

struct HotkeyShortcut: Codable, Hashable, Identifiable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayName: String

    var id: String { "\(keyCode)-\(carbonModifiers)" }

    static let defaultShortcut = HotkeyShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey),
        displayName: "⌥ Space"
    )

    static let presets: [HotkeyShortcut] = [
        .defaultShortcut,
        HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey), displayName: "⌃ Space"),
        HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), displayName: "⌃⌥ Space"),
        HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey), displayName: "⌘⇧ Space")
    ]
}

@MainActor
final class SettingsStore: ObservableObject {
    static let defaultPrompt = "Transcribe an English software-engineering instruction accurately. Preserve technical names, filenames, file paths, shell commands, command-line flags, URLs, version numbers, variable names, class names, acronyms, and quoted text. Relevant vocabulary includes Codex, Claude Code, Git, GitHub, Swift, SwiftUI, Xcode, Kotlin, Java, TypeScript, JavaScript, Python, Docker, npm, pnpm, Homebrew, Jira, SVN, ESP32, STM32, macOS, iOS, Android, API, JSON, YAML, SQL, SQLite, OpenRouter, Traxxas, and Firebase. Use normal punctuation and capitalization."

    private enum Key {
        static let showHUD = "showHUD"
        static let playSounds = "playSounds"
        static let automaticallyInsert = "automaticallyInsert"
        static let copyToClipboard = "copyToClipboard"
        static let maximumRecordingDuration = "maximumRecordingDuration"
        static let model = "transcriptionModel"
        static let language = "transcriptionLanguage"
        static let prompt = "transcriptionPrompt"
        static let hotkey = "hotkeyShortcut"
        static let debugLogging = "debugLogging"
    }

    private let defaults: UserDefaults

    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: Key.showHUD) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    @Published var automaticallyInsert: Bool { didSet { defaults.set(automaticallyInsert, forKey: Key.automaticallyInsert) } }
    @Published var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Key.copyToClipboard) } }
    @Published var maximumRecordingDuration: Double { didSet { defaults.set(maximumRecordingDuration, forKey: Key.maximumRecordingDuration) } }
    @Published var model: TranscriptionModel { didSet { defaults.set(model.rawValue, forKey: Key.model) } }
    @Published var language: TranscriptionLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published var transcriptionPrompt: String { didSet { defaults.set(transcriptionPrompt, forKey: Key.prompt) } }
    @Published var hotkey: HotkeyShortcut { didSet { persistHotkey() } }
    @Published var debugLogging: Bool { didSet { defaults.set(debugLogging, forKey: Key.debugLogging) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showHUD: true,
            Key.playSounds: true,
            Key.automaticallyInsert: true,
            Key.copyToClipboard: false,
            Key.maximumRecordingDuration: 300.0,
            Key.model: TranscriptionModel.mini.rawValue,
            Key.language: TranscriptionLanguage.english.rawValue,
            Key.prompt: Self.defaultPrompt,
            Key.debugLogging: false
        ])

        showHUD = defaults.bool(forKey: Key.showHUD)
        playSounds = defaults.bool(forKey: Key.playSounds)
        automaticallyInsert = defaults.bool(forKey: Key.automaticallyInsert)
        copyToClipboard = defaults.bool(forKey: Key.copyToClipboard)
        maximumRecordingDuration = min(max(defaults.double(forKey: Key.maximumRecordingDuration), 10), 300)
        model = TranscriptionModel(rawValue: defaults.string(forKey: Key.model) ?? "") ?? .mini
        language = TranscriptionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
        transcriptionPrompt = defaults.string(forKey: Key.prompt) ?? Self.defaultPrompt
        debugLogging = defaults.bool(forKey: Key.debugLogging)

        if let data = defaults.data(forKey: Key.hotkey),
           let decoded = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            hotkey = decoded
        } else {
            hotkey = .defaultShortcut
        }
    }

    func resetPrompt() {
        transcriptionPrompt = Self.defaultPrompt
    }

    func restoreDefaultHotkey() {
        hotkey = .defaultShortcut
    }

    private func persistHotkey() {
        guard let data = try? JSONEncoder().encode(hotkey) else { return }
        defaults.set(data, forKey: Key.hotkey)
    }
}
