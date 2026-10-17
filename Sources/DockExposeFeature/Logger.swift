import os

/// Debug logging for the ported Dockmint code. Messages go to the unified log only.
enum Logger {
    private static let log = os.Logger(subsystem: "com.apotenza.SimpleMacFixes", category: "DockAppExpose")

    static func log(_ message: @autoclosure () -> String) {
        let text = message()
        log.notice("\(text, privacy: .public)")
    }

    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        log.debug("\(text, privacy: .public)")
    }
}
