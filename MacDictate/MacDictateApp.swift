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
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioOutputController.restoreAfterDictation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
