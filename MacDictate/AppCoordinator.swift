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
    private let contextProvider: DictationContextProviding
    let transcriptionHistory: TranscriptionHistory

    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var welcomeWindowController: WelcomeWindowController?
    private var correctionWindowController: CorrectionWindowController?
    private var hudController: HUDController?
    private var stateCancellable: AnyCancellable?
    private var hotkeyCancellable: AnyCancellable?
    private var extendedHotkeyCancellable: AnyCancellable?
    private var hotkeyStatusCancellable: AnyCancellable?
    private var workspaceObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var activeWorkflowID: UUID?
    private var workflowTask: Task<Void, Never>?
    private var contextEnrichmentTask: Task<DictationContextSnapshot, Never>?
    private var capturedContext: DictationContextSnapshot?
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
        fileCleaner: TemporaryFileCleaning = TemporaryFileCleaner(),
        transcriptionHistory: TranscriptionHistory = TranscriptionHistory(),
        contextProvider: DictationContextProviding = DefaultDictationContextProvider()
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
        self.transcriptionHistory = transcriptionHistory
        self.contextProvider = contextProvider
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        fileCleaner.cleanupStaleRecordings()
        configureMenuBar()
        configureSettingsWindow()
        hudController = HUDController(
            stateMachine: stateMachine,
            settings: settings,
            audioRecorder: audioRecorder
        )
        // Show onboarding only when it can help: a brand-new install (no flag,
        // no key) or a first run that was never acknowledged. Existing users
        // upgrading with a working key keep their quiet menu-bar launch.
        let hasStoredKey = ((try? credentialStore.load()) ?? nil) != nil
        if !settings.hasCompletedSetup, !hasStoredKey {
            showWelcomeWindow()
        }

        audioRecorder.onInterruption = { [weak self] reason in
            self?.fail(AudioRecorderError.engineFailed(reason))
        }
        audioRecorder.onInputDeviceFallback = { [weak self] selection in
            guard let self else { return }
            let previousSelection = self.settings.audioInputSelection
            self.settings.fallbackAudioInputSelection = previousSelection
            self.settings.audioInputSelection = selection
            self.statusBarController?.refreshMicrophoneMenu()
        }
        audioRecorder.onInputDeviceReconnection = { [weak self] selection in
            guard let self else { return }
            self.settings.audioInputSelection = selection
            self.statusBarController?.refreshMicrophoneMenu()
        }

        do {
            try audioRecorder.selectInputDevice(settings.audioInputSelection)
        } catch {
            AppLogger.audio.error(
                "Saved input device is currently unavailable: \(error.localizedDescription, privacy: .public)"
            )
        }

        hotkeyManager.onKeyDown = { [weak self] in self?.beginDictation() }
        hotkeyManager.onKeyUp = { [weak self] in self?.finishDictation() }
        hotkeyManager.register(settings.hotkey, for: .laptop)
        if settings.extendedKeyboardHotkeyEnabled {
            hotkeyManager.register(settings.extendedKeyboardHotkey, for: .extendedKeyboard)
        }

        hotkeyCancellable = settings.$hotkey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shortcut in
                MainActor.assumeIsolated { self?.applyHotkey(shortcut) }
            }
        extendedHotkeyCancellable = settings.$extendedKeyboardHotkeyEnabled
            .combineLatest(settings.$extendedKeyboardHotkey)
            .dropFirst()
            .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
            .sink { [weak self] isEnabled, shortcut in
                MainActor.assumeIsolated {
                    self?.applyExtendedKeyboardHotkey(shortcut, isEnabled: isEnabled)
                }
            }
        stateCancellable = stateMachine.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.updateMenu(for: state) }
        }
        hotkeyStatusCancellable = hotkeyManager.$registrationStatus
            .combineLatest(hotkeyManager.$extendedKeyboardRegistrationStatus)
            .dropFirst()
            .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateMenu(for: self.stateMachine.state)
                }
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

    private func applyHotkey(_ shortcut: HotkeyShortcut) {
        // A failed replacement restores the previous Carbon registration and then
        // rolls the setting back asynchronously. Keep the conflict visible instead
        // of re-registering that restored shortcut and overwriting the error status.
        if hotkeyManager.activeShortcut(for: .laptop) == shortcut { return }
        if hotkeyManager.register(shortcut, for: .laptop) { return }
        guard let restored = hotkeyManager.activeShortcut(for: .laptop) else { return }
        // $hotkey publishes before the property is assigned, so reverting here would be
        // overwritten by the in-flight assignment — and then persisted by its didSet.
        Task { @MainActor [weak self] in
            self?.settings.hotkey = restored
        }
    }

    private func applyExtendedKeyboardHotkey(
        _ shortcut: HotkeyShortcut,
        isEnabled: Bool
    ) {
        guard isEnabled else {
            hotkeyManager.unregister(.extendedKeyboard)
            return
        }
        if hotkeyManager.activeShortcut(for: .extendedKeyboard) == shortcut { return }
        if hotkeyManager.register(shortcut, for: .extendedKeyboard) { return }
        guard let restored = hotkeyManager.activeShortcut(for: .extendedKeyboard) else { return }
        // As above, defer the persisted rollback until the published assignment completes.
        Task { @MainActor [weak self] in
            self?.settings.extendedKeyboardHotkey = restored
        }
    }

    func beginDictation() {
        switch stateMachine.state {
        case .transcribing, .inserting:
            AppLogger.hotkey.info("Cancelling the active delivery workflow from the hotkey")
            cancelActive()
            return
        default:
            break
        }
        guard audioRecorder.isReadyForRecording else {
            AppLogger.hotkey.info("Ignoring hotkey while the previous microphone session finishes closing")
            return
        }
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
        let target: TargetApplication
        do {
            target = try captureTargetApplication()
            capturedTarget = target
            lastErrorDetails = nil
            try stateMachine.transition(to: .preparing)
        } catch {
            fail(error)
            return
        }
        let workflowID = UUID()
        activeWorkflowID = workflowID

        workflowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audioRecorder.prepare()
                try Task.checkCancellation()
                guard self.activeWorkflowID == workflowID else { return }
                try self.audioRecorder.start()
                // Capture context after the microphone is already recording so AX
                // queries never delay audio capture or clip the user's first words.
                self.startContextCapture(for: target)
                // Starting the engine also queries the input-device graph.
                // Finish those queries before a process mute tap changes it.
                try self.beginSystemAudioSilencing(for: workflowID)
                try self.stateMachine.transition(to: .recording(startedAt: Date()))
                self.playSound(named: "Pop")
                self.scheduleMaximumDuration(for: workflowID)
            } catch is CancellationError {
                guard self.activeWorkflowID == workflowID else { return }
                self.cancelActive(showMessage: true)
            } catch {
                guard self.activeWorkflowID == workflowID else { return }
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
            guard let activeWorkflowID else { return }
            finishRecording(
                elapsed: Date().timeIntervalSince(reference),
                enforceMinimum: true,
                workflowID: activeWorkflowID
            )
        default:
            break
        }
    }

    func cancelActive(showMessage: Bool = true) {
        guard stateMachine.state.isActive else { return }
        let workflowID = activeWorkflowID
        activeWorkflowID = nil
        workflowTask?.cancel()
        workflowTask = nil
        clearCapturedContext()
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        audioRecorder.cancel()
        if let workflowID {
            restoreSystemAudio(for: workflowID)
        }
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
        let workflowID = activeWorkflowID
        activeWorkflowID = nil
        workflowTask?.cancel()
        workflowTask = nil
        clearCapturedContext()
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        audioRecorder.cancel()
        if let workflowID {
            restoreSystemAudio(for: workflowID)
        }
        try? stateMachine.transition(to: .cancelled(message: message))
        scheduleReset()
    }

    private func finishRecording(
        elapsed: TimeInterval,
        enforceMinimum: Bool,
        workflowID: UUID
    ) {
        guard activeWorkflowID == workflowID else { return }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        if enforceMinimum, !RecordingPolicy.shouldTranscribe(elapsed: elapsed) {
            activeWorkflowID = nil
            clearCapturedContext()
            audioRecorder.cancel()
            restoreSystemAudio(for: workflowID)
            do {
                try stateMachine.transition(
                    to: .cancelled(message: "Pressed too briefly — hold while speaking.")
                )
                scheduleReset(after: 2.0)
            } catch {
                fail(error)
            }
            return
        }

        do {
            let recordedAudio = try audioRecorder.stop()
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
                await self?.transcribeAndInsert(
                    recordedAudio,
                    target: target,
                    workflowID: workflowID
                )
            }
        } catch {
            guard activeWorkflowID == workflowID else { return }
            fail(error)
        }
    }

    private func transcribeAndInsert(
        _ recording: RecordedAudio,
        target: TargetApplication,
        workflowID: UUID
    ) async {
        defer { fileCleaner.delete(recording.fileURL) }
        do {
            guard activeWorkflowID == workflowID else { return }
            guard let key = try credentialStore.load(), !key.isEmpty else {
                throw TranscriptionError.missingAPIKey
            }
            let resolvedContext = await resolveCapturedContext()
            try Task.checkCancellation()
            guard activeWorkflowID == workflowID else { return }
            if let resolvedContext {
                let repoName = resolvedContext.gitContext?.repositoryName ?? "none"
                let keyCount = resolvedContext.gitContext?.issueKeys.count ?? 0
                AppLogger.transcription.info(
                    "Active context: app=\(resolvedContext.appName, privacy: .public), repo=\(repoName, privacy: .public), issueKeys=\(keyCount, privacy: .public)"
                )
            }
            let effectivePrompt = DictationContextComposer.composePrompt(
                basePrompt: settings.transcriptionPrompt,
                learnedHints: settings.learnedPromptHints,
                context: resolvedContext
            )
            let configuration = TranscriptionConfiguration(
                apiKey: key,
                model: settings.model,
                language: settings.language,
                contextPrompt: effectivePrompt
            )
            let rawTranscript = try await transcriptionService.transcribe(
                fileURL: recording.fileURL,
                configuration: configuration
            )
            try Task.checkCancellation()
            guard activeWorkflowID == workflowID else { return }

            // Only check prompt echoes against static prompt sections (base prompt + learned hints),
            // never against dynamic quoted `Recent dictation` or `Text before cursor`, so repeating
            // the same 30+ character instruction twice within 5 minutes is never discarded.
            let staticPrompt = DictationContextComposer.composePrompt(
                basePrompt: settings.transcriptionPrompt,
                learnedHints: settings.learnedPromptHints,
                context: nil
            )
            let isPromptEcho = PromptEchoDetector.isLikelyEcho(
                transcript: rawTranscript,
                contextPrompt: settings.transcriptionPrompt
            ) || PromptEchoDetector.isLikelyEcho(
                transcript: rawTranscript,
                contextPrompt: staticPrompt
            )
            guard !isPromptEcho else {
                AppLogger.transcription.info("Discarding a transcription that echoes the context prompt")
                cancelBenignly(message: "No speech detected")
                return
            }

            let transcript = TranscriptPostProcessor.apply(
                settings.learnedReplacements,
                to: rawTranscript
            )

            transcriptionHistory.add(transcript)
            statusBarController?.refreshRecentTranslationsMenu()

            var completionMessage = "Transcription complete"
            var insertionOutcome: TextInsertionOutcome?
            if settings.automaticallyInsert {
                try stateMachine.transition(to: .inserting)
                let outcome = try await insertionService.insert(transcript, target: target)
                try Task.checkCancellation()
                guard activeWorkflowID == workflowID else { return }
                insertionOutcome = outcome
                switch outcome {
                case .accessibility, .keyboardEvents, .clipboardPaste:
                    completionMessage = "Text inserted"
                case .pasteDispatched:
                    completionMessage = "Paste sent"
                case .automaticInsertionUnverified:
                    completionMessage = "Insertion unconfirmed"
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
                if let insertionOutcome {
                    switch insertionOutcome {
                    case .accessibility, .keyboardEvents, .clipboardPaste:
                        completionMessage = "Inserted and copied"
                    case .pasteDispatched:
                        completionMessage = "Paste sent and copied"
                    case .automaticInsertionUnverified:
                        completionMessage = "Insertion unconfirmed"
                    case .copiedForManualPaste:
                        completionMessage = "Copied—press ⌘V to paste"
                    }
                }
            }
            try stateMachine.transition(to: .completed(message: completionMessage))
            restoreSystemAudio(for: workflowID)
            activeWorkflowID = nil
            workflowTask = nil
            playSound(named: "Glass")
            if settings.debugLogging {
                AppLogger.transcription.debug("Transcription completed; audio duration \(recording.duration, privacy: .public)s, transcript length \(transcript.count, privacy: .public)")
            }
            scheduleReset()
        } catch is CancellationError {
            guard activeWorkflowID == workflowID else { return }
            if stateMachine.state.isActive { cancelActive(showMessage: false) }
        } catch TranscriptionError.emptyTranscription {
            guard activeWorkflowID == workflowID else { return }
            cancelBenignly(message: "No speech detected")
        } catch {
            guard activeWorkflowID == workflowID else { return }
            fail(error)
        }
    }

    private func scheduleMaximumDuration(for workflowID: UUID) {
        maximumDurationTask?.cancel()
        let duration = settings.maximumRecordingDuration
        maximumDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            guard self.activeWorkflowID == workflowID else { return }
            if case let .recording(startedAt) = self.stateMachine.state {
                self.finishRecording(
                    elapsed: Date().timeIntervalSince(startedAt),
                    enforceMinimum: false,
                    workflowID: workflowID
                )
            }
        }
    }

    private func beginSystemAudioSilencing(for workflowID: UUID) throws {
        guard settings.muteSystemAudioDuringDictation else { return }
        try audioOutputController.silenceForDictation(workflowID: workflowID)
    }

    private func startContextCapture(for target: TargetApplication) {
        clearCapturedContext()
        guard settings.includeActiveContext else { return }
        let recent = transcriptionHistory.mostRecent(within: 300)
        let immediate = contextProvider.captureImmediateContext(
            for: target,
            recentTranscription: recent
        )
        capturedContext = immediate
        let provider = contextProvider
        contextEnrichmentTask = Task {
            await provider.enrichContext(immediate, target: target)
        }
    }

    private func resolveCapturedContext() async -> DictationContextSnapshot? {
        guard settings.includeActiveContext else {
            clearCapturedContext()
            return nil
        }
        // Detach without cancelling the task we are about to await.
        let fallback = capturedContext
        let task = contextEnrichmentTask
        contextEnrichmentTask = nil
        capturedContext = nil
        guard let task else { return fallback }

        // Bound wait after key-up to 250 ms so slow Git/SVN never stalls transcription;
        // enrichment starts when recording begins, so it is almost always already complete.
        return await withTaskGroup(of: DictationContextSnapshot?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first {
                return first
            }
            task.cancel()
            return fallback
        }
    }

    private func clearCapturedContext() {
        contextEnrichmentTask?.cancel()
        contextEnrichmentTask = nil
        capturedContext = nil
    }

    private func fail(_ error: Error) {
        let workflowID = activeWorkflowID
        activeWorkflowID = nil
        workflowTask?.cancel()
        workflowTask = nil
        clearCapturedContext()
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        audioRecorder.cancel()
        if let workflowID {
            restoreSystemAudio(for: workflowID)
        }
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
        scheduleReset(after: 4.0)
    }

    private func restoreSystemAudio(for workflowID: UUID) {
        audioOutputController.restoreAfterDictation(workflowID: workflowID)
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

    func shutdown() {
        activeWorkflowID = nil
        workflowTask?.cancel()
        workflowTask = nil
        clearCapturedContext()
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        resetTask?.cancel()
        resetTask = nil
        audioRecorder.cancel()
    }

    private func configureMenuBar() {
        statusBarController = StatusBarController(
            settings: settings,
            stateMachine: stateMachine,
            hotkeyManager: hotkeyManager,
            audioRecorder: audioRecorder,
            transcriptionHistory: transcriptionHistory,
            actions: StatusBarController.Actions(
                start: { [weak self] in self?.beginDictation() },
                stop: { [weak self] in self?.stopFromMenu() },
                cancel: { [weak self] in self?.cancelActive() },
                copyLastError: { [weak self] in self?.copyLastError() },
                copyRecentTranslation: { [weak self] translation in
                    self?.insertionService.copy(translation)
                },
                correctLastTranscription: { [weak self] in self?.openCorrectionWindow() },
                selectMicrophone: { [weak self] selection in
                    self?.selectMicrophone(selection)
                },
                openSettings: { [weak self] in self?.openSettings() },
                openAccessibilitySettings: { [weak self] in self?.accessibilityPermission.openSettings() },
                openMicrophoneSettings: { [weak self] in self?.microphonePermission.openSettings() }
            )
        )
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
        statusBarController?.update(for: state, hasErrorDetails: lastErrorDetails != nil)
    }

    private func showWelcomeWindow() {
        let view = WelcomeView(
            settings: settings,
            credentials: CredentialSettingsModel(store: credentialStore),
            microphonePermission: microphonePermission,
            accessibilityPermission: accessibilityPermission,
            hotkeyManager: hotkeyManager,
            onFinish: { [weak self] in
                self?.settings.hasCompletedSetup = true
                self?.dismissWelcomeWindow()
            },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        welcomeWindowController = WelcomeWindowController(rootView: view)
        welcomeWindowController?.show()
    }

    private func dismissWelcomeWindow() {
        welcomeWindowController?.dismiss()
        welcomeWindowController = nil
    }

    private func stopFromMenu() {
        // Menu-initiated stops are always deliberate; skip the short-press minimum.
        if case let .recording(startedAt) = stateMachine.state,
           let activeWorkflowID {
            finishRecording(
                elapsed: Date().timeIntervalSince(startedAt),
                enforceMinimum: false,
                workflowID: activeWorkflowID
            )
        }
    }

    private func selectMicrophone(_ selection: AudioInputSelection) {
        guard stateMachine.state == .idle else { return }
        do {
            let previousSelection = settings.audioInputSelection
            try audioRecorder.selectInputDevice(selection)
            if selection != previousSelection {
                settings.fallbackAudioInputSelection = previousSelection
            }
            settings.audioInputSelection = selection
            statusBarController?.refreshMicrophoneMenu()
        } catch {
            fail(error)
        }
    }

    private func openSettings() { settingsWindowController?.show() }

    private func openCorrectionWindow() {
        let entries = transcriptionHistory.entries
        guard !entries.isEmpty, !stateMachine.state.isActive else { return }
        if let existing = correctionWindowController {
            existing.show()
            return
        }
        let returnTarget = lastExternalTarget
        var controller: CorrectionWindowController?
        let dismissAction: () -> Void = { [weak self] in
            guard let self else { return }
            if self.correctionWindowController === controller {
                self.correctionWindowController?.dismiss()
                self.correctionWindowController = nil
            }
            if let returnTarget,
               let app = NSRunningApplication(processIdentifier: returnTarget.processIdentifier),
               !app.isTerminated {
                app.activate(options: [])
            }
        }
        let viewModel = CorrectionViewModel(
            entries: entries,
            settings: settings,
            credentialStore: credentialStore,
            onApplyCorrected: { [weak self] index, corrected in
                guard let self else { return }
                self.transcriptionHistory.replace(at: index, with: corrected)
                self.statusBarController?.refreshRecentTranslationsMenu()
                self.insertionService.copy(corrected)
            },
            onDismiss: dismissAction
        )
        let newController = CorrectionWindowController(viewModel: viewModel) {
            viewModel.cancel()
        }
        controller = newController
        correctionWindowController = newController
        newController.show()
    }

    private func copyLastError() {
        guard let lastErrorDetails else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastErrorDetails, forType: .string)
    }
}
