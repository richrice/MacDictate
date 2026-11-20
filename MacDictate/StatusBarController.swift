import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Actions {
        let start: () -> Void
        let stop: () -> Void
        let cancel: () -> Void
        let copyLastError: () -> Void
        let copyRecentTranslation: (String) -> Void
        let correctLastTranscription: () -> Void
        let selectMicrophone: (AudioInputSelection) -> Void
        let openSettings: () -> Void
        let openAccessibilitySettings: () -> Void
        let openMicrophoneSettings: () -> Void
    }

    private let settings: SettingsStore
    private let stateMachine: DictationStateMachine
    private let hotkeyManager: GlobalHotkeyManager
    private let audioRecorder: AudioRecording
    private let transcriptionHistory: TranscriptionHistory
    private let actions: Actions

    private let statusItem: NSStatusItem
    private let statusMenuItem: NSMenuItem
    private let startMenuItem: NSMenuItem
    private let stopMenuItem: NSMenuItem
    private let cancelMenuItem: NSMenuItem
    private let copyErrorMenuItem: NSMenuItem
    private let recentTranslationsMenuItem: NSMenuItem
    private let recentTranslationsMenu: NSMenu
    private let correctLastMenuItem: NSMenuItem
    private let microphoneMenuItem: NSMenuItem
    private let microphoneMenu: NSMenu
    private var microphoneMenuSelections: [Int: AudioInputSelection] = [:]

    init(
        settings: SettingsStore,
        stateMachine: DictationStateMachine,
        hotkeyManager: GlobalHotkeyManager,
        audioRecorder: AudioRecording,
        transcriptionHistory: TranscriptionHistory,
        actions: Actions
    ) {
        self.settings = settings
        self.stateMachine = stateMachine
        self.hotkeyManager = hotkeyManager
        self.audioRecorder = audioRecorder
        self.transcriptionHistory = transcriptionHistory
        self.actions = actions

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MacDictate")
        statusItem.button?.toolTip = "MacDictate — Ready"

        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let start = NSMenuItem(title: "Start Dictation", action: #selector(handleStart), keyEquivalent: "")
        menu.addItem(start)
        let stop = NSMenuItem(title: "Stop and Transcribe", action: #selector(handleStop), keyEquivalent: "")
        stop.isEnabled = false
        menu.addItem(stop)
        let cancel = NSMenuItem(title: "Cancel Current Dictation", action: #selector(handleCancel), keyEquivalent: "")
        cancel.isEnabled = false
        menu.addItem(cancel)
        let copyError = NSMenuItem(title: "Copy Last Error Details", action: #selector(handleCopyLastError), keyEquivalent: "")
        copyError.isHidden = true
        menu.addItem(copyError)

        let recentTranslationsItem = NSMenuItem(
            title: "Recent Transcriptions",
            action: nil,
            keyEquivalent: ""
        )
        let recentTranslationsMenu = NSMenu(title: "Recent Transcriptions")
        recentTranslationsItem.submenu = recentTranslationsMenu
        menu.addItem(recentTranslationsItem)
        let correctLast = NSMenuItem(
            title: "Correct Last Transcription…",
            action: #selector(handleCorrectLastTranscription),
            keyEquivalent: ""
        )
        correctLast.isEnabled = false
        menu.addItem(correctLast)
        menu.addItem(.separator())

        let microphonePickerItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let microphoneMenu = NSMenu(title: "Microphone")
        microphonePickerItem.submenu = microphoneMenu
        menu.addItem(microphonePickerItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleOpenSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(handleOpenAccessibilitySettings), keyEquivalent: "")
        menu.addItem(accessibilityItem)
        let microphoneItem = NSMenuItem(title: "Open Microphone Settings", action: #selector(handleOpenMicrophoneSettings), keyEquivalent: "")
        menu.addItem(microphoneItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        self.statusItem = statusItem
        self.statusMenuItem = status
        self.startMenuItem = start
        self.stopMenuItem = stop
        self.cancelMenuItem = cancel
        self.copyErrorMenuItem = copyError
        self.recentTranslationsMenuItem = recentTranslationsItem
        self.recentTranslationsMenu = recentTranslationsMenu
        self.correctLastMenuItem = correctLast
        self.microphoneMenuItem = microphonePickerItem
        self.microphoneMenu = microphoneMenu
        super.init()

        menu.delegate = self
        start.target = self
        stop.target = self
        cancel.target = self
        copyError.target = self
        correctLast.target = self
        settingsItem.target = self
        accessibilityItem.target = self
        microphoneItem.target = self

        refreshMicrophoneMenu()
        refreshRecentTranslationsMenu()
    }

    private var hasHotkeyRegistrationProblem: Bool {
        if hotkeyManager.registrationStatus.isProblem { return true }
        return settings.extendedKeyboardHotkeyEnabled
            && hotkeyManager.extendedKeyboardRegistrationStatus.isProblem
    }

    func update(for state: DictationPhase, hasErrorDetails: Bool) {
        var statusText = state.statusText
        if state == .idle, hasHotkeyRegistrationProblem {
            statusText = "Shortcut unavailable — choose another in Settings…"
        }
        statusMenuItem.title = statusText
        startMenuItem.isEnabled = state == .idle
        if case .recording = state {
            stopMenuItem.isEnabled = true
        } else {
            stopMenuItem.isEnabled = false
        }
        cancelMenuItem.isEnabled = state.isActive
        copyErrorMenuItem.isHidden = !hasErrorDetails
        microphoneMenuItem.isEnabled = state == .idle
        refreshRecentTranslationsMenu()

        let symbol: String
        switch state {
        case .recording: symbol = "mic.fill"
        case .preparing, .transcribing, .inserting: symbol = "ellipsis.circle"
        case .failed: symbol = "exclamationmark.triangle.fill"
        case .idle where hasHotkeyRegistrationProblem: symbol = "exclamationmark.triangle.fill"
        default: symbol = "waveform"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        statusItem.button?.toolTip = "MacDictate — \(statusText)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMicrophoneMenu()
        refreshRecentTranslationsMenu()
    }

    func refreshRecentTranslationsMenu() {
        recentTranslationsMenu.removeAllItems()

        let entries = transcriptionHistory.entries
        let canUseHistory = !entries.isEmpty && !stateMachine.state.isActive
        recentTranslationsMenuItem.isEnabled = canUseHistory
        correctLastMenuItem.isEnabled = canUseHistory
        guard !entries.isEmpty else {
            let emptyItem = NSMenuItem(title: "No recent transcriptions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentTranslationsMenu.addItem(emptyItem)
            return
        }

        for (index, translation) in entries.enumerated() {
            let item = NSMenuItem(
                title: "\(index + 1). \(Self.recentTranslationTitle(translation))",
                action: #selector(handleCopyRecentTranslation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = translation
            item.toolTip = translation
            item.isEnabled = !stateMachine.state.isActive
            recentTranslationsMenu.addItem(item)
        }
    }

    func refreshMicrophoneMenu() {
        microphoneMenu.removeAllItems()
        microphoneMenuSelections.removeAll()
        microphoneMenuItem.title = "Microphone: \(audioRecorder.currentInputDeviceName)"

        var nextTag = 0
        let systemDefaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(handleSelectMicrophone(_:)),
            keyEquivalent: ""
        )
        systemDefaultItem.target = self
        systemDefaultItem.tag = nextTag
        systemDefaultItem.state = settings.audioInputSelection == .systemDefault ? .on : .off
        systemDefaultItem.isEnabled = stateMachine.state == .idle
        microphoneMenuSelections[nextTag] = .systemDefault
        microphoneMenu.addItem(systemDefaultItem)
        nextTag += 1

        let devices = audioRecorder.availableInputDevices
        if !devices.isEmpty {
            microphoneMenu.addItem(.separator())
        }
        for device in devices {
            let selection = device.selection
            let item = NSMenuItem(
                title: device.name,
                action: #selector(handleSelectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = nextTag
            item.state = settings.audioInputSelection.uid == device.uid ? .on : .off
            item.isEnabled = stateMachine.state == .idle
            microphoneMenuSelections[nextTag] = selection
            microphoneMenu.addItem(item)
            nextTag += 1
        }

        if case let .device(uid, name) = settings.audioInputSelection,
           !devices.contains(where: { $0.uid == uid }) {
            microphoneMenu.addItem(.separator())
            let unavailable = NSMenuItem(
                title: "\(name) (Unavailable)",
                action: nil,
                keyEquivalent: ""
            )
            unavailable.state = .on
            unavailable.isEnabled = false
            microphoneMenu.addItem(unavailable)
        } else if devices.isEmpty {
            let unavailable = NSMenuItem(
                title: "No microphones available",
                action: nil,
                keyEquivalent: ""
            )
            unavailable.isEnabled = false
            microphoneMenu.addItem(unavailable)
        }
    }

    private static func recentTranslationTitle(_ translation: String) -> String {
        let oneLine = translation.components(separatedBy: .newlines).joined(separator: " ")
        let limit = 72
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit - 1)) + "…"
    }

    @objc private func handleStart() { actions.start() }
    @objc private func handleStop() { actions.stop() }
    @objc private func handleCancel() { actions.cancel() }
    @objc private func handleCopyLastError() { actions.copyLastError() }
    @objc private func handleCorrectLastTranscription() { actions.correctLastTranscription() }
    @objc private func handleOpenSettings() { actions.openSettings() }
    @objc private func handleOpenAccessibilitySettings() { actions.openAccessibilitySettings() }
    @objc private func handleOpenMicrophoneSettings() { actions.openMicrophoneSettings() }

    @objc private func handleCopyRecentTranslation(_ sender: NSMenuItem) {
        guard !stateMachine.state.isActive,
              let translation = sender.representedObject as? String else { return }
        actions.copyRecentTranslation(translation)
    }

    @objc private func handleSelectMicrophone(_ sender: NSMenuItem) {
        guard stateMachine.state == .idle,
              let selection = microphoneMenuSelections[sender.tag] else {
            return
        }
        actions.selectMicrophone(selection)
    }
}
