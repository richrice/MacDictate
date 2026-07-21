import AppKit
import Foundation

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
        hotkeyStatus: HotkeyRegistrationStatus
    ) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let lines = [
            "MacDictate diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "State: \(state.statusText)",
            "Microphone permission: \(microphone.rawValue)",
            "Accessibility permission: \(accessibility.rawValue)",
            "API key configured: \(hasAPIKey ? "yes" : "no")",
            "Model: \(settings.model.rawValue)",
            "Language: \(settings.language.rawValue)",
            "Hotkey: \(settings.hotkey.displayName)",
            "Hotkey registration: \(hotkeyStatus.displayText)",
            "HUD enabled: \(settings.showHUD)",
            "Sounds enabled: \(settings.playSounds)",
            "Automatic insertion: \(settings.automaticallyInsert)",
            "Copy transcription: \(settings.copyToClipboard)",
            "Debug logging: \(settings.debugLogging)"
        ]
        return SecretRedactor.redact(lines.joined(separator: "\n"))
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    static func openLogsFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}

