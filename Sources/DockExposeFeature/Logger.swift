import os

/// Debug logging for the ported Dockmint code. Messages go to the unified log only.
enum Logger {
    private static let osLog = OSLog(subsystem: "com.apotenza.SimpleMacFixes", category: "DockAppExpose")
    private static let log = os.Logger(osLog)

    static func log(_ message: @autoclosure () -> String) {
        let text = message()
        log.notice("\(text, privacy: .public)")
    }

    /// The message is only built while debug logging is switched on: hit tests log on every lookup.
    static func debug(_ message: @autoclosure () -> String) {
        guard osLog.isEnabled(type: .debug) else { return }
        let text = message()
        log.debug("\(text, privacy: .public)")
    }
}
