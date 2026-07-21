@preconcurrency import AVFoundation
import AppKit
import ApplicationServices

enum PermissionStatus: String, Sendable {
    case granted = "Granted"
    case denied = "Denied"
    case notDetermined = "Not requested"
    case restricted = "Restricted"
    case unknown = "Unknown"
}

@MainActor
protocol MicrophonePermissionProviding: AnyObject {
    func request() async -> Bool
}

@MainActor
final class MicrophonePermissionManager: ObservableObject, MicrophonePermissionProviding {
    @Published private(set) var status: PermissionStatus = .unknown

    init() {
        refresh()
    }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: status = .granted
        case .denied: status = .denied
        case .notDetermined: status = .notDetermined
        case .restricted: status = .restricted
        @unknown default: status = .unknown
        }
    }

    func request() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
        return status == .granted
    }

    func openSettings() {
        SystemSettings.openPrivacyPane(anchor: "Privacy_Microphone")
    }
}

@MainActor
protocol AccessibilityPermissionProviding: AnyObject {
    func requestIfNeeded() -> Bool
}

@MainActor
final class AccessibilityPermissionManager: ObservableObject, AccessibilityPermissionProviding {
    @Published private(set) var status: PermissionStatus = .unknown
    private var hasPromptedThisLaunch = false

    init() {
        refresh()
    }

    func refresh() {
        status = AXIsProcessTrusted() ? .granted : .denied
    }

    func requestIfNeeded() -> Bool {
        refresh()
        guard status != .granted else { return true }
        if !hasPromptedThisLaunch {
            hasPromptedThisLaunch = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
        return status == .granted
    }

    func openSettings() {
        SystemSettings.openPrivacyPane(anchor: "Privacy_Accessibility")
    }
}

enum SystemSettings {
    @MainActor
    static func openPrivacyPane(anchor: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }
}
