import AppKit
import SwiftUI

@MainActor
final class CredentialSettingsModel: ObservableObject {
    @Published var enteredKey = ""
    @Published private(set) var isConfigured = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var isVerifying = false
    @Published private(set) var verification: APIKeyVerification?

    private let store: SecureCredentialStore
    private let verifier: OpenAIKeyVerifier

    init(store: SecureCredentialStore, verifier: OpenAIKeyVerifier = OpenAIKeyVerifier()) {
        self.store = store
        self.verifier = verifier
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
            verification = nil
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
            verification = nil
            statusMessage = "API key deleted from Keychain."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Verifies the typed key before saving, or the stored key when the field
    /// is empty, against a cheap authenticated endpoint.
    func verify() {
        guard !isVerifying else { return }
        let candidate = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyToCheck: String?
        if candidate.isEmpty {
            keyToCheck = try? store.load()
        } else {
            keyToCheck = candidate
        }
        guard let keyToCheck, !keyToCheck.isEmpty else {
            verification = .couldNotVerify("Enter a key first.")
            return
        }
        isVerifying = true
        verification = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await verifier.verify(keyToCheck)
            isVerifying = false
            verification = outcome
        }
    }

    var canVerify: Bool {
        !isVerifying && (!enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConfigured)
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
    @StateObject private var deviceMonitor = AudioDeviceListMonitor()
    @State private var inputDeviceError: String?
    @State private var supportFeedback: String?

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
            deviceMonitor.refresh()
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
                Toggle("Mute system audio until text is delivered", isOn: $settings.muteSystemAudioDuringDictation)
                Toggle("Automatically insert transcription", isOn: $settings.automaticallyInsert)
                Toggle("Keep a copy on the clipboard", isOn: $settings.copyToClipboard)
            }
            Section("Recording") {
                Picker("Input device", selection: Binding(
                    get: { settings.audioInputSelection },
                    set: { selectInputDevice($0) }
                )) {
                    Text("System Default").tag(AudioInputSelection.systemDefault)
                    ForEach(deviceMonitor.availableInputDevices) { device in
                        Text(device.name).tag(device.selection)
                    }
                    if case let .device(uid, name) = settings.audioInputSelection,
                       !deviceMonitor.availableInputDevices.contains(where: { $0.uid == uid }) {
                        Text("\(name) (Unavailable)")
                            .tag(settings.audioInputSelection)
                    }
                }
                .disabled(stateMachine.state.isActive)
                LabeledContent("Active microphone", value: activeMicrophoneDisplayName)
                Text("The selection applies only to MacDictate and is remembered between launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let inputDeviceError {
                    Text(inputDeviceError)
                        .font(.caption)
                        .foregroundStyle(.red)
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

    private var activeMicrophoneDisplayName: String {
        switch settings.audioInputSelection {
        case .systemDefault:
            return deviceMonitor.defaultInputDeviceName
        case let .device(uid, name):
            return deviceMonitor.availableInputDevices.first(where: { $0.uid == uid })?.name
                ?? "\(name) (Unavailable)"
        }
    }

    private func selectInputDevice(_ selection: AudioInputSelection) {
        do {
            let previousSelection = settings.audioInputSelection
            try audioRecorder.selectInputDevice(selection)
            if selection != previousSelection {
                settings.fallbackAudioInputSelection = previousSelection
            }
            settings.audioInputSelection = selection
            inputDeviceError = nil
        } catch {
            inputDeviceError = error.localizedDescription
        }
    }

    private var hotkeyTab: some View {
        Form {
            Section("MacBook keyboard") {
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
            }
            Section("Extended keyboard") {
                Toggle("Enable a second shortcut", isOn: $settings.extendedKeyboardHotkeyEnabled)
                Picker("Shortcut", selection: $settings.extendedKeyboardHotkey) {
                    ForEach(HotkeyShortcut.extendedKeyboardShortcuts) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                .disabled(!settings.extendedKeyboardHotkeyEnabled)
                Text("The laptop shortcut remains available. Right Control is dedicated to dictation while selected, so choose an F-key if you use it in other shortcuts. F13–F15 may map to Print Screen, Scroll Lock, or Pause on some keyboards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.extendedKeyboardHotkeyEnabled,
                   settings.extendedKeyboardHotkey == .defaultExtendedKeyboardShortcut,
                   accessibilityPermission.status != .granted {
                    Label(
                        "Right Control requires Accessibility permission to receive key presses in other apps.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Section("Registration") {
                registrationRow(
                    label: "Laptop",
                    status: hotkeyManager.registrationStatus
                )
                registrationRow(
                    label: "Extended keyboard",
                    status: hotkeyManager.extendedKeyboardRegistrationStatus
                )
                Text("Registration detects ordinary shortcuts reserved by other apps. Modifier-only shortcuts and extra actions emitted by keyboard hardware or remapping software cannot be checked for conflicts.")
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
                    Button(credentials.isVerifying ? "Verifying…" : "Verify") { credentials.verify() }
                        .disabled(!credentials.canVerify)
                    Button("Delete Key", role: .destructive) { credentials.delete() }
                        .disabled(!credentials.isConfigured)
                    Spacer()
                    Text(credentials.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let verification = credentials.verification {
                    Text(verificationMessage(for: verification))
                        .font(.caption)
                        .foregroundStyle(verificationColor(for: verification))
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
                Text("Required to insert text into the application that was focused when recording began, and to use the Right Control shortcut. Without it, MacDictate copies the transcript for manual paste.")
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
                HStack {
                    Button("Copy Redacted Diagnostics") { copyDiagnostics() }
                    Button("Copy Recent Logs") { copyRecentLogs() }
                    Button("Open Console") { AppDiagnostics.openConsoleApp() }
                }
                if let supportFeedback {
                    Text(supportFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func verificationMessage(for outcome: APIKeyVerification) -> String {
        switch outcome {
        case .valid: "Verified — the key was accepted by OpenAI."
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

    @ViewBuilder
    private func permissionRow(status: PermissionStatus) -> some View {
        HStack {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status == .granted ? .green : .orange)
            Text(status.rawValue)
        }
    }

    private func hotkeyStatusSymbol(for status: HotkeyRegistrationStatus) -> String {
        switch status {
        case .registered: "checkmark.circle.fill"
        case .conflict, .failed: "exclamationmark.triangle.fill"
        case .notRegistered: "minus.circle"
        }
    }

    private func hotkeyStatusColor(for status: HotkeyRegistrationStatus) -> Color {
        switch status {
        case .registered: .green
        case .conflict, .failed: .orange
        case .notRegistered: .secondary
        }
    }

    private func registrationRow(
        label: String,
        status: HotkeyRegistrationStatus
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: hotkeyStatusSymbol(for: status))
                .foregroundStyle(hotkeyStatusColor(for: status))
            Text("\(label): \(status.displayText)")
        }
    }

    private func copyDiagnostics() {
        let text = AppDiagnostics.make(
            settings: settings,
            state: stateMachine.state,
            microphone: microphonePermission.status,
            accessibility: accessibilityPermission.status,
            hasAPIKey: credentials.isConfigured,
            hotkeyStatus: hotkeyManager.registrationStatus,
            extendedKeyboardHotkeyStatus: hotkeyManager.extendedKeyboardRegistrationStatus,
            activeInputDeviceName: audioRecorder.currentInputDeviceName
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        supportFeedback = "Redacted diagnostics copied to clipboard."
    }

    private func copyRecentLogs() {
        let logs = AppDiagnostics.recentLogs()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs, forType: .string)
        supportFeedback = "Recent redacted logs copied to clipboard."
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
