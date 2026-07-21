import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage = ""

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = "Enabled"
        case .requiresApproval:
            isEnabled = false
            statusMessage = "Requires approval in Login Items"
        case .notRegistered:
            isEnabled = false
            statusMessage = "Disabled"
        case .notFound:
            isEnabled = false
            statusMessage = "Available after the app is installed in Applications"
        @unknown default:
            isEnabled = false
            statusMessage = "Unknown status"
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            statusMessage = error.localizedDescription
            AppLogger.settings.error("Launch-at-login update failed: \(error.localizedDescription, privacy: .public)")
            refreshKeepingError(error.localizedDescription)
        }
    }

    private func refreshKeepingError(_ error: String) {
        isEnabled = SMAppService.mainApp.status == .enabled
        statusMessage = error
    }
}

