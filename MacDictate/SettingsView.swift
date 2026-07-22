import AppKit
import SwiftUI

@MainActor
final class CredentialSettingsModel: ObservableObject {
    @Published var enteredKey = ""
    @Published private(set) var isConfigured = false
    @Published private(set) var statusMessage = ""

    private let store: SecureCredentialStore

    init(store: SecureCredentialStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        do {
            isConfigured = try store.load() != nil
            statusMessage = isConfigured ? "Configured (••••••••)" : "No API key configured"
        } catch {
            isConfigured = false
            statusMessage = error.localizedDescription
        }
    }

    func save() {
        let trimmed = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Enter an API key first."
            return
        }
        do {
            try store.save(trimmed)
            enteredKey = ""
            isConfigured = true
            statusMessage = "API key saved securely in Keychain."
        } catch {
            enteredKey = ""
            statusMessage = error.localizedDescription
        }
    }

    func delete() {
        do {
            try store.delete()
            enteredKey = ""
            isConfigured = false
            statusMessage = "API key deleted from Keychain."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var stateMachine: DictationStateMachine
    @ObservedObject var hotkeyManager: GlobalHotkeyManager
    @ObservedObject var microphonePermission: MicrophonePermissionManager
    @ObservedObject var accessibilityPermission: AccessibilityPermissionManager
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @StateObject private var credentials: CredentialSettingsModel

    let audioRecorder: AudioRecording

    init(
        settings: SettingsStore,
        stateMachine: DictationStateMachine,
        hotkeyManager: GlobalHotkeyManager,
        microphonePermission: MicrophonePermissionManager,
        accessibilityPermission: AccessibilityPermissionManager,
        launchAtLogin: LaunchAtLoginManager,
        credentialStore: SecureCredentialStore,
        audioRecorder: AudioRecording
    ) {
        self.settings = settings
        self.stateMachine = stateMachine
        self.hotkeyManager = hotkeyManager
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.launchAtLogin = launchAtLogin
        self.audioRecorder = audioRecorder
        _credentials = StateObject(wrappedValue: CredentialSettingsModel(store: credentialStore))
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            hotkeyTab
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            openAITab
                .tabItem { Label("OpenAI", systemImage: "waveform.badge.magnifyingglass") }
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 690, height: 590)
        .padding(16)
        .onAppear {
            microphonePermission.refresh()
            accessibilityPermission.refresh()
            launchAtLogin.refresh()
            credentials.refresh()
        }
    }

    private var generalTab: some View {
        Form {
            Section("Behavior") {
                Toggle("Launch MacDictate at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if !launchAtLogin.statusMessage.isEmpty {
                    Text(launchAtLogin.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show floating status HUD", isOn: $settings.showHUD)
                Toggle("Play subtle feedback sounds", isOn: $settings.playSounds)
                Toggle("Automatically insert transcription", isOn: $settings.automaticallyInsert)
                Toggle("Leave transcription on clipboard", isOn: $settings.copyToClipboard)
            }
            Section("Recording") {
                LabeledContent("Input device", value: audioRecorder.currentInputDeviceName)
                if audioRecorder.availableInputDeviceNames.count > 1 {
                    Text("MacDictate follows the input device selected in macOS Sound settings. Available: \(audioRecorder.availableInputDeviceNames.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Maximum duration")
                    Slider(value: $settings.maximumRecordingDuration, in: 10...300, step: 10)
                    Text("\(Int(settings.maximumRecordingDuration)) sec")
                        .monospacedDigit()
                        .frame(width: 55, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeyTab: some View {
        Form {
            Section("Push to talk") {
                LabeledContent("Current shortcut", value: settings.hotkey.displayName)
                Picker("Change shortcut", selection: $settings.hotkey) {
                    ForEach(HotkeyShortcut.presetGroups) { group in
                        Section(group.name) {
                            ForEach(group.shortcuts) { shortcut in
                                Text(shortcut.displayName).tag(shortcut)
                            }
                        }
                    }
                }
                Button("Restore Default (\(HotkeyShortcut.defaultShortcut.displayName))") {
                    settings.restoreDefaultHotkey()
                }
                Text("Bare function keys (F13–F19) are reserved system-wide by MacDictate while it is running. These keys are typically available only on full-size or extended external keyboards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Registration") {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: hotkeyStatusSymbol)
                        .foregroundStyle(hotkeyStatusColor)
                    Text(hotkeyManager.registrationStatus.displayText)
                }
                Text("The shortcut is consumed by MacDictate. Key down starts recording and key up transcribes; key repeat cannot start another session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var openAITab: some View {
        Form {
            Section("API key") {
                SecureField("sk-…", text: $credentials.enteredKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(credentials.isConfigured ? "Replace Key" : "Save Key") { credentials.save() }
                        .disabled(credentials.enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Delete Key", role: .destructive) { credentials.delete() }
                        .disabled(!credentials.isConfigured)
                    Spacer()
                    Text(credentials.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("The key is stored only in macOS Keychain and is never placed in preferences or diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Transcription") {
                Picker("Model", selection: $settings.model) {
                    ForEach(TranscriptionModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
            Section("Developer vocabulary context") {
                TextEditor(text: $settings.transcriptionPrompt)
                    .font(.body)
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                HStack {
                    Text("This context helps the model; it does not guarantee exact spelling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") { settings.resetPrompt() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var permissionsTab: some View {
        Form {
            Section("Microphone") {
                permissionRow(status: microphonePermission.status)
                Text("Required to capture audio while push-to-talk is held. MacDictate does not record in the background.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Request Access") { Task { _ = await microphonePermission.request() } }
                    Button("Open Microphone Settings") { microphonePermission.openSettings() }
                }
            }
            Section("Accessibility") {
                permissionRow(status: accessibilityPermission.status)
                Text("Required to insert text into the application that was focused when recording began. Without it, MacDictate copies the transcript for manual paste.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Request Access") { _ = accessibilityPermission.requestIfNeeded() }
                    Button("Open Accessibility Settings") { accessibilityPermission.openSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var diagnosticsTab: some View {
        Form {
            Section("Application") {
                LabeledContent("Version", value: AppDiagnostics.versionDescription)
                LabeledContent("Current status", value: stateMachine.state.statusText)
                Toggle("Enable debug logging", isOn: $settings.debugLogging)
                Text("Logs record state, durations, and sizes—not API keys, transcripts, clipboard contents, or audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Support") {
                Button("Copy Redacted Diagnostics") { copyDiagnostics() }
                Button("Open Logs Folder") { AppDiagnostics.openLogsFolder() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(status: PermissionStatus) -> some View {
        HStack {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status == .granted ? .green : .orange)
            Text(status.rawValue)
        }
    }

    private var hotkeyStatusSymbol: String {
        switch hotkeyManager.registrationStatus {
        case .registered: "checkmark.circle.fill"
        case .conflict, .failed: "exclamationmark.triangle.fill"
        case .notRegistered: "minus.circle"
        }
    }

    private var hotkeyStatusColor: Color {
        switch hotkeyManager.registrationStatus {
        case .registered: .green
        case .conflict, .failed: .orange
        case .notRegistered: .secondary
        }
    }

    private func copyDiagnostics() {
        let text = AppDiagnostics.make(
            settings: settings,
            state: stateMachine.state,
            microphone: microphonePermission.status,
            accessibility: accessibilityPermission.status,
            hasAPIKey: credentials.isConfigured,
            hotkeyStatus: hotkeyManager.registrationStatus
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(rootView: SettingsView) {
        let hostingController = NSHostingController(rootView: rootView)
        window = NSWindow(contentViewController: hostingController)
        window.title = "MacDictate Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MacDictateSettingsWindow")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
