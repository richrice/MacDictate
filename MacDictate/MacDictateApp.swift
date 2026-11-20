import AppKit
import SwiftUI

@main
struct MacDictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Route ⌘, and the app menu's Settings item to the real settings
            // window instead of the placeholder SwiftUI Settings scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .macDictateOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: AppCoordinator
    private let audioOutputController: SystemAudioOutputController

    override init() {
        let settings = SettingsStore()
        let stateMachine = DictationStateMachine()
        let hotkeyManager = GlobalHotkeyManager()
        let microphonePermission = MicrophonePermissionManager()
        let accessibilityPermission = AccessibilityPermissionManager()
        let launchAtLogin = LaunchAtLoginManager()
        let audioRecorder = AudioRecorder(
            permissionManager: microphonePermission,
            inputSelection: settings.audioInputSelection,
            fallbackInputSelection: settings.fallbackAudioInputSelection
        )
        let credentialStore = KeychainCredentialStore()
        let clipboard = ClipboardManager()
        let audioOutputController = SystemAudioOutputController()
        let insertionService = DefaultTextInsertionService(
            permissionManager: accessibilityPermission,
            directInserter: AccessibilityDirectInserter(),
            keyboardInserter: UnicodeKeyboardTextInserter(),
            pasteInserter: ClipboardPasteInserter(clipboard: clipboard),
            clipboard: clipboard
        )
        self.audioOutputController = audioOutputController
        coordinator = AppCoordinator(
            settings: settings,
            stateMachine: stateMachine,
            hotkeyManager: hotkeyManager,
            microphonePermission: microphonePermission,
            accessibilityPermission: accessibilityPermission,
            launchAtLogin: launchAtLogin,
            audioRecorder: audioRecorder,
            transcriptionService: OpenAITranscriptionService(),
            credentialStore: credentialStore,
            insertionService: insertionService,
            audioOutputController: audioOutputController
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside this app as their test host; don't register the
        // global hotkey or build the menu bar during a test run.
        guard NSClassFromString("XCTestCase") == nil else { return }

        // Carbon hot keys are not exclusive: a second instance registering the
        // same shortcut also receives the event, so both would record the same
        // speech and insert the transcript twice.
        guard !Self.anotherInstanceIsRunning() else {
            AppLogger.lifecycle.error("Another MacDictate instance is already running; quitting")
            presentDuplicateInstanceAlert()
            NSApp.terminate(nil)
            return
        }
        coordinator.start()
    }

    private static func anotherInstanceIsRunning() -> Bool {
        isDuplicateInstance(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            ownProcessID: ProcessInfo.processInfo.processIdentifier,
            runningInstances: NSWorkspace.shared.runningApplications.map {
                ($0.bundleIdentifier, $0.processIdentifier)
            }
        )
    }

    /// Split out from the NSWorkspace lookup so the matching rule is testable.
    static func isDuplicateInstance(
        bundleIdentifier: String?,
        ownProcessID: pid_t,
        runningInstances: [(bundleIdentifier: String?, processIdentifier: pid_t)]
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return runningInstances.contains {
            $0.bundleIdentifier == bundleIdentifier
                && $0.processIdentifier != ownProcessID
        }
    }

    private func presentDuplicateInstanceAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MacDictate is already running"
        alert.informativeText = """
            Another copy is already handling the dictation shortcut. Quit it \
            from the menu bar before launching this one.
            """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
        audioOutputController.restoreImmediately()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
