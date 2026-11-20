import AppKit
import Foundation
import OSLog

enum SecretRedactor {
    static func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)Bearer\s+[A-Za-z0-9._~+\-/]+=*"#,
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            #"(?i)(api[_ -]?key\s*[:=]\s*)\S+"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: pattern.localizedCaseInsensitiveContains("api") ? "$1<redacted>" : "<redacted>",
                options: .regularExpression
            )
        }
        return result
    }
}

@MainActor
enum AppDiagnostics {
    static func make(
        settings: SettingsStore,
        state: DictationPhase,
        microphone: PermissionStatus,
        accessibility: PermissionStatus,
        hasAPIKey: Bool,
        hotkeyStatus: HotkeyRegistrationStatus,
        extendedKeyboardHotkeyStatus: HotkeyRegistrationStatus,
        activeInputDeviceName: String? = nil
    ) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        var lines = [
            "MacDictate diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "State: \(state.statusText)",
            "Microphone permission: \(microphone.rawValue)",
            "Accessibility permission: \(accessibility.rawValue)",
            "API key configured: \(hasAPIKey ? "yes" : "no")",
            "Model: \(settings.model.rawValue)",
            "Language: \(settings.language.rawValue)",
            "Input device preference: \(settings.audioInputSelection.displayName)"
        ]
        if let activeInputDeviceName {
            lines.append("Active microphone: \(activeInputDeviceName)")
        }
        lines.append(contentsOf: [
            "Mute system audio during dictation: \(settings.muteSystemAudioDuringDictation)",
            "Laptop hotkey: \(settings.hotkey.displayName)",
            "Laptop hotkey registration: \(hotkeyStatus.displayText)",
            "Extended keyboard hotkey enabled: \(settings.extendedKeyboardHotkeyEnabled)",
            "Extended keyboard hotkey: \(settings.extendedKeyboardHotkey.displayName)",
            "Extended keyboard hotkey registration: \(extendedKeyboardHotkeyStatus.displayText)",
            "HUD enabled: \(settings.showHUD)",
            "Sounds enabled: \(settings.playSounds)",
            "Automatic insertion: \(settings.automaticallyInsert)",
            "Copy transcription: \(settings.copyToClipboard)",
            "Debug logging: \(settings.debugLogging)"
        ])
        return SecretRedactor.redact(lines.joined(separator: "\n"))
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    static func recentLogs(limit: Int = 200) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@", AppLogger.subsystem)
            let entries = try store.getEntries(matching: predicate)
                .compactMap { $0 as? OSLogEntryLog }
            let formatter = ISO8601DateFormatter()
            let formatted = entries.suffix(limit).map { entry in
                "\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)"
            }
            guard !formatted.isEmpty else {
                return "No MacDictate log entries recorded during this session."
            }
            return SecretRedactor.redact(formatted.joined(separator: "\n"))
        } catch {
            return "Unable to read unified logs: \(error.localizedDescription)"
        }
    }

    static func openConsoleApp() {
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(consoleURL)
    }
}
