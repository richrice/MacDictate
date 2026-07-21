import Foundation
import OSLog

enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.macdictate.app"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let insertion = Logger(subsystem: subsystem, category: "insertion")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}

