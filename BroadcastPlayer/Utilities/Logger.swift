import Foundation
import OSLog

nonisolated enum Log {
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.broadcastplayer.BroadcastPlayer"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let render = Logger(subsystem: subsystem, category: "render")
}