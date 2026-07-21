import AppKit
import SwiftUI

@main
struct MacDictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: AppCoordinator

    override init() {
        let settings = SettingsStore()
        let stateMachine = DictationStateMachine()
        let hotkeyManager = GlobalHotkeyManager()
        let microphonePermission = MicrophonePermissionManager()
        let accessibilityPermission = AccessibilityPermissionManager()
        let launchAtLogin = LaunchAtLoginManager()
        let audioRecorder = AudioRecorder(permissionManager: microphonePermission)
        let credentialStore = KeychainCredentialStore()
        let clipboard = ClipboardManager()
        let insertionService = DefaultTextInsertionService(
            permissionManager: accessibilityPermission,
            directInserter: AccessibilityDirectInserter(),
            pasteInserter: ClipboardPasteInserter(clipboard: clipboard),
            clipboard: clipboard
        )
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
            insertionService: insertionService
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
