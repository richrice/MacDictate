import AppKit
import Combine
import Foundation

enum DictationCoordinatorError: LocalizedError, Equatable {
    case noTargetApplication

    var errorDescription: String? {
        switch self {
        case .noTargetApplication: "Focus the application where you want text inserted, then try again."
        }
    }
}

extension Notification.Name {
    static let macDictateOpenSettings = Notification.Name("com.macdictate.openSettings")
}

enum RecordingPolicy {
    static let minimumDuration: TimeInterval = 0.25

    static func shouldTranscribe(elapsed: TimeInterval) -> Bool {
        elapsed >= minimumDuration
    }
}

@MainActor
final class AppCoordinator: NSObject {
    let settings: SettingsStore
    let stateMachine: DictationStateMachine
    let hotkeyManager: GlobalHotkeyManager
    let microphonePermission: MicrophonePermissionManager
    let accessibilityPermission: AccessibilityPermissionManager
    let launchAtLogin: LaunchAtLoginManager

    private let audioRecorder: AudioRecording
    private let transcriptionService: TranscriptionService
    private let credentialStore: SecureCredentialStore
    private let insertionService: TextInsertionService
    private let audioOutputController: SystemAudioOutputControlling
    private let fileCleaner: TemporaryFileCleaning

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var startMenuItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?
    private var cancelMenuItem: NSMenuItem?
    private var copyErrorMenuItem: NSMenuItem?
    private var settingsWindowController: SettingsWindowController?
    private var hudController: HUDController?
    private var stateCancellable: AnyCancellable?
    private var hotkeyCancellable: AnyCancellable?
    private var workspaceObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var workflowTask: Task<Void, Never>?
    private var muteTask: Task<Void, Never>?
    private var maximumDurationTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var capturedTarget: TargetApplication?
    private var hotkeyPressedAt: Date?
    var lastExternalTarget: TargetApplication?
    private(set) var lastErrorDetails: String?

    init(
        settings: SettingsStore,
        stateMachine: DictationStateMachine,
        hotkeyManager: GlobalHotkeyManager,
        microphonePermission: MicrophonePermissionManager,
        accessibilityPermission: AccessibilityPermissionManager,
        launchAtLogin: LaunchAtLoginManager,
        audioRecorder: AudioRecording,
        transcriptionService: TranscriptionService,
        credentialStore: SecureCredentialStore,
        insertionService: TextInsertionService,
        audioOutputController: SystemAudioOutputControlling,
        fileCleaner: TemporaryFileCleaning = TemporaryFileCleaner()
    ) {
        self.settings = settings
        self.stateMachine = stateMachine
        self.hotkeyManager = hotkeyManager
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.launchAtLogin = launchAtLogin
        self.audioRecorder = audioRecorder
        self.transcriptionService = transcriptionService
        self.credentialStore = credentialStore
        self.insertionService = insertionService
        self.audioOutputController = audioOutputController
        self.fileCleaner = fileCleaner
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()
        configureSettingsWindow()
        hudController = HUDController(stateMachine: stateMachine, settings: settings)

        hotkeyManager.onKeyDown = { [weak self] in self?.beginDictation() }
        hotkeyManager.onKeyUp = { [weak self] in self?.finishDictation() }
        audioRecorder.onInterruption = { [weak self] reason in
            self?.fail(AudioRecorderError.engineFailed(reason))
        }
        hotkeyManager.register(settings.hotkey)

        hotkeyCancellable = settings.$hotkey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shortcut in
                MainActor.assumeIsolated { self?.hotkeyManager.register(shortcut) }
            }
        stateCancellable = stateMachine.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.updateMenu(for: state) }
        }

        observeApplicationActivation()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .macDictateOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWindowController?.show() }
        }
        rememberFrontmostApplication()
        AppLogger.lifecycle.info("MacDictate launched")
    }

    func beginDictation() {
        // A press during the brief terminal-state display should start a new
        // dictation immediately instead of being silently dropped.
        if stateMachine.state.isTerminal {
            resetTask?.cancel()
            resetTask = nil
            stateMachine.resetAfterTerminalState()
            capturedTarget = nil
        }
        guard stateMachine.state == .idle else {
            AppLogger.hotkey.info("Ignoring hotkey because a dictation workflow is active")
            return
        }
        hotkeyPressedAt = Date()
        do {
            capturedTarget = try captureTargetApplication()
            lastErrorDetails = nil
            try stateMachine.transition(to: .preparing)
        } catch {
            fail(error)
            return
        }

        workflowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audioRecorder.prepare()
                try Task.checkCancellation()
                try self.audioRecorder.start()
                try self.stateMachine.transition(to: .recording(startedAt: Date()))
                self.playSound(named: "Pop")
                self.scheduleMute()
                self.scheduleMaximumDuration()
            } catch is CancellationError {
                self.cancelActive(showMessage: true)
            } catch {
                self.fail(error)
            }
        }
    }

    func finishDictation() {
        switch stateMachine.state {
        case .preparing:
            cancelActive(showMessage: true)
        case let .recording(startedAt):
            // Measure the hold from key-down, not recording start, so prepare()
            // latency cannot cancel a press the user legitimately held.
            let reference = hotkeyPressedAt ?? startedAt
            finishRecording(elapsed: Date().timeIntervalSince(reference), enforceMinimum: true)
        default:
            break
        }
    }

    func cancelActive(showMessage: Bool = true) {
        guard stateMachine.state.isActive else { return }
        workflowTask?.cancel()
        workflowTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        audioRecorder.cancel()
        muteTask?.cancel()
        muteTask = nil
        audioOutputController.restoreAfterDictation()
        do {
            try stateMachine.transition(to: .cancelled(message: nil))
            if showMessage { AppLogger.lifecycle.info("Dictation cancelled") }
            scheduleReset()
        } catch {
            AppLogger.lifecycle.error("Cancellation state error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends the workflow without treating the outcome as an error: no failure
    /// sound, no error details, just a short status message.
    private func cancelBenignly(message: String) {
        guard stateMachine.state.isActive else { return }
        workflowTask?.cancel()
        workflowTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        audioRecorder.cancel()
        muteTask?.cancel()
        muteTask = nil
        audioOutputController.restoreAfterDictation()
        try? stateMachine.transition(to: .cancelled(message: message))
        scheduleReset()
    }

    private func finishRecording(elapsed: TimeInterval, enforceMinimum: Bool) {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        if enforceMinimum, !RecordingPolicy.shouldTranscribe(elapsed: elapsed) {
            audioRecorder.cancel()
            muteTask?.cancel()
            muteTask = nil
            audioOutputController.restoreAfterDictation()
            do {
                try stateMachine.transition(to: .cancelled(message: nil))
                scheduleReset()
            } catch {
                fail(error)
            }
            return
        }

        do {
            let recordedAudio = try audioRecorder.stop()
            muteTask?.cancel()
            muteTask = nil
            audioOutputController.restoreAfterDictation()
            playSound(named: "Tink")
            guard !recordedAudio.isEffectivelySilent else {
                fileCleaner.delete(recordedAudio.fileURL)
                cancelBenignly(message: "No speech detected")
                return
            }
            guard let target = capturedTarget else {
                fileCleaner.delete(recordedAudio.fileURL)
                throw DictationCoordinatorError.noTargetApplication
            }
            try stateMachine.transition(to: .transcribing)
            workflowTask = Task { [weak self] in
                await self?.transcribeAndInsert(recordedAudio, target: target)
            }
        } catch {
            fail(error)
        }
    }

    private func transcribeAndInsert(_ recording: RecordedAudio, target: TargetApplication) async {
        defer { fileCleaner.delete(recording.fileURL) }
        do {
            guard let key = try credentialStore.load(), !key.isEmpty else {
                throw TranscriptionError.missingAPIKey
            }
            let configuration = TranscriptionConfiguration(
                apiKey: key,
                model: settings.model,
                language: settings.language,
                contextPrompt: settings.transcriptionPrompt
            )
            let transcript = try await transcriptionService.transcribe(
                fileURL: recording.fileURL,
                configuration: configuration
            )
            try Task.checkCancellation()

            guard !PromptEchoDetector.isLikelyEcho(transcript: transcript, contextPrompt: settings.transcriptionPrompt) else {
                AppLogger.transcription.info("Discarding a transcription that echoes the context prompt")
                cancelBenignly(message: "No speech detected")
                return
            }

            var completionMessage = "Transcription complete"
            if settings.automaticallyInsert {
                try stateMachine.transition(to: .inserting)
                let outcome = try await insertionService.insert(transcript, target: target)
                switch outcome {
                case .accessibility, .clipboardPaste:
                    completionMessage = "Text inserted"
                case .copiedForManualPaste:
                    completionMessage = "Copied—press ⌘V to paste"
                }
            } else {
                insertionService.copy(transcript)
                completionMessage = "Copied—press ⌘V to paste"
            }

            // When automatic insertion is off, the transcript was already copied above.
            if settings.copyToClipboard, settings.automaticallyInsert {
                insertionService.copy(transcript)
                completionMessage = "Inserted and copied"
            }
            try stateMachine.transition(to: .completed(message: completionMessage))
            playSound(named: "Glass")
            if settings.debugLogging {
                AppLogger.transcription.debug("Transcription completed; audio duration \(recording.duration, privacy: .public)s, transcript length \(transcript.count, privacy: .public)")
            }
            scheduleReset()
        } catch is CancellationError {
            if stateMachine.state.isActive { cancelActive(showMessage: false) }
        } catch TranscriptionError.emptyTranscription {
            cancelBenignly(message: "No speech detected")
        } catch {
            fail(error)
        }
    }

    private func scheduleMaximumDuration() {
        maximumDurationTask?.cancel()
        let duration = settings.maximumRecordingDuration
        maximumDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            if case let .recording(startedAt) = self.stateMachine.state {
                self.finishRecording(elapsed: Date().timeIntervalSince(startedAt), enforceMinimum: false)
            }
        }
    }

    private func scheduleMute() {
        guard settings.muteSystemAudioDuringDictation else { return }
        guard settings.playSounds else {
            // No start sound to protect; mute immediately.
            audioOutputController.muteForDictation()
            return
        }
        muteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            guard case .recording = self.stateMachine.state else { return }
            self.audioOutputController.muteForDictation()
        }
    }

    private func fail(_ error: Error) {
        workflowTask?.cancel()
        workflowTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        audioRecorder.cancel()
        muteTask?.cancel()
        muteTask = nil
        audioOutputController.restoreAfterDictation()
        let friendly = error.localizedDescription
        lastErrorDetails = SecretRedactor.redact(String(reflecting: error))
        AppLogger.lifecycle.error("Dictation failed: \(friendly, privacy: .public)")

        if stateMachine.state.isActive {
            try? stateMachine.transition(to: .failed(message: friendly))
        } else if case .idle = stateMachine.state {
            // A target-capture failure occurs before preparing can begin.
            try? stateMachine.transition(to: .preparing)
            try? stateMachine.transition(to: .failed(message: friendly))
        }
        playSound(named: "Basso")
        // Errors stay visible longer than routine terminal states so the HUD
        // message can actually be read before the state resets to idle.
        scheduleReset(after: 3.0)
    }

    private func scheduleReset(after seconds: Double = 1.3) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stateMachine.resetAfterTerminalState()
            self?.capturedTarget = nil
        }
    }

    private func playSound(named name: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func captureTargetApplication() throws -> TargetApplication {
        rememberFrontmostApplication()
        guard let target = lastExternalTarget else { throw DictationCoordinatorError.noTargetApplication }
        return target
    }

    private func rememberFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalTarget = TargetApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName ?? "Unknown application"
        )
    }

    private func observeApplicationActivation() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.lastExternalTarget = TargetApplication(
                    processIdentifier: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.localizedName ?? "Unknown application"
                )
            }
        }
    }

    private func configureMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MacDictate")
        statusItem.button?.toolTip = "MacDictate — Ready"
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let start = NSMenuItem(title: "Start Dictation", action: #selector(startFromMenu), keyEquivalent: "")
        start.target = self
        menu.addItem(start)
        let stop = NSMenuItem(title: "Stop and Transcribe", action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = false
        menu.addItem(stop)
        let cancel = NSMenuItem(title: "Cancel Current Dictation", action: #selector(cancelFromMenu), keyEquivalent: "")
        cancel.target = self
        cancel.isEnabled = false
        menu.addItem(cancel)
        let copyError = NSMenuItem(title: "Copy Last Error Details", action: #selector(copyLastError), keyEquivalent: "")
        copyError.target = self
        copyError.isHidden = true
        menu.addItem(copyError)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        let microphoneItem = NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: "")
        microphoneItem.target = self
        menu.addItem(microphoneItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        self.statusItem = statusItem
        statusMenuItem = status
        startMenuItem = start
        stopMenuItem = stop
        cancelMenuItem = cancel
        copyErrorMenuItem = copyError
    }

    private func configureSettingsWindow() {
        let view = SettingsView(
            settings: settings,
            stateMachine: stateMachine,
            hotkeyManager: hotkeyManager,
            microphonePermission: microphonePermission,
            accessibilityPermission: accessibilityPermission,
            launchAtLogin: launchAtLogin,
            credentialStore: credentialStore,
            audioRecorder: audioRecorder
        )
        settingsWindowController = SettingsWindowController(rootView: view)
    }

    private func updateMenu(for state: DictationPhase) {
        statusMenuItem?.title = state.statusText
        startMenuItem?.isEnabled = state == .idle
        if case .recording = state {
            stopMenuItem?.isEnabled = true
        } else {
            stopMenuItem?.isEnabled = false
        }
        cancelMenuItem?.isEnabled = state.isActive
        copyErrorMenuItem?.isHidden = lastErrorDetails == nil

        let symbol: String
        switch state {
        case .recording: symbol = "mic.fill"
        case .preparing, .transcribing, .inserting: symbol = "ellipsis.circle"
        case .failed: symbol = "exclamationmark.triangle.fill"
        default: symbol = "waveform"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.statusText)
        statusItem?.button?.toolTip = "MacDictate — \(state.statusText)"
    }

    @objc private func startFromMenu() { beginDictation() }

    @objc private func stopFromMenu() {
        // Menu-initiated stops are always deliberate; skip the short-press minimum.
        if case let .recording(startedAt) = stateMachine.state {
            finishRecording(elapsed: Date().timeIntervalSince(startedAt), enforceMinimum: false)
        }
    }

    @objc private func cancelFromMenu() { cancelActive() }
    @objc private func openSettings() { settingsWindowController?.show() }
    @objc private func openAccessibilitySettings() { accessibilityPermission.openSettings() }
    @objc private func openMicrophoneSettings() { microphonePermission.openSettings() }

    @objc private func copyLastError() {
        guard let lastErrorDetails else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastErrorDetails, forType: .string)
    }
}
