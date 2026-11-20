import AppKit
import SwiftUI

@MainActor
struct WelcomeView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var credentials: CredentialSettingsModel
    @ObservedObject var microphonePermission: MicrophonePermissionManager
    @ObservedObject var accessibilityPermission: AccessibilityPermissionManager
    @ObservedObject var hotkeyManager: GlobalHotkeyManager
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to MacDictate")
                    .font(.title2.weight(.semibold))
                Text("Three quick steps and you can dictate anywhere you can type.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            apiKeySection
            Divider()
            microphoneSection
            Divider()
            accessibilitySection

            hotkeyFootnote

            HStack {
                Button("Open Settings…") { onOpenSettings() }
                Spacer()
                Button("Get Started") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            microphonePermission.refresh()
            accessibilityPermission.refresh()
            credentials.refresh()
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepHeader(number: 1, title: "Add your OpenAI API key")
            HStack(spacing: 8) {
                SecureField("sk-…", text: $credentials.enteredKey)
                    .textFieldStyle(.roundedBorder)
                Button(credentials.isConfigured ? "Replace" : "Save") { credentials.save() }
                    .disabled(credentials.enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let verification = credentials.verification {
                Text(verificationText(for: verification))
                    .font(.caption)
                    .foregroundStyle(verificationColor(for: verification))
            } else {
                Text(credentials.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Stored only in macOS Keychain. You can verify it before saving in Settings → OpenAI.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stepHeader(number: 2, title: "Allow microphone access")
                Spacer()
                Button("Request Access") {
                    Task { _ = await microphonePermission.request() }
                }
                .disabled(microphonePermission.status == .granted)
            }
            permissionCaption(microphonePermission.status)
            if microphonePermission.status == .denied {
                Button("Open Microphone Settings") { microphonePermission.openSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stepHeader(number: 3, title: "Allow accessibility access (optional)")
                Spacer()
                Button("Request Access") { _ = accessibilityPermission.requestIfNeeded() }
                    .disabled(accessibilityPermission.status == .granted)
            }
            Text("Needed to insert text automatically and to use the Right Control shortcut. Without it, each transcript is copied so you can press ⌘V.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if accessibilityPermission.status == .denied {
                Button("Open Accessibility Settings") { accessibilityPermission.openSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var hotkeyFootnote: some View {
        Group {
            if hotkeyManager.registrationStatus.isProblem {
                Label(
                    "The \(settings.hotkey.displayName) shortcut could not be registered — choose another under Settings → Hotkey.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else if settings.extendedKeyboardHotkeyEnabled,
                      hotkeyManager.extendedKeyboardRegistrationStatus.isProblem {
                Label(
                    "The extended-keyboard shortcut \(settings.extendedKeyboardHotkey.displayName) is already in use. The laptop shortcut still works.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else {
                Label(
                    settings.extendedKeyboardHotkeyEnabled
                        ? "To dictate: hold \(settings.hotkey.displayName) or \(settings.extendedKeyboardHotkey.displayName), speak, then release."
                        : "To dictate: hold \(settings.hotkey.displayName), speak, then release.",
                    systemImage: "keyboard"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func stepHeader(number: Int, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
            Text(title).font(.headline)
        }
    }

    private func permissionCaption(_ status: PermissionStatus) -> Text {
        switch status {
        case .granted:
            Text("Granted").font(.caption).foregroundColor(.green)
        case .notDetermined:
            Text("Not requested — macOS will ask when you click Request Access.").font(.caption).foregroundStyle(.secondary)
        default:
            Text("Denied — enable MacDictate in System Settings, then relaunch it.").font(.caption).foregroundStyle(.orange)
        }
    }

    private func verificationText(for outcome: APIKeyVerification) -> String {
        switch outcome {
        case .valid: "Verified — accepted by OpenAI."
        case let .invalid(detail): "Rejected — \(detail)"
        case let .couldNotVerify(detail): "Could not verify — \(detail)"
        }
    }

    private func verificationColor(for outcome: APIKeyVerification) -> Color {
        switch outcome {
        case .valid: .green
        case .invalid: .red
        case .couldNotVerify: .orange
        }
    }
}

@MainActor
final class WelcomeWindowController {
    private let window: NSWindow

    init(rootView: WelcomeView) {
        let hostingController = NSHostingController(rootView: rootView)
        window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to MacDictate"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window.close()
    }
}
