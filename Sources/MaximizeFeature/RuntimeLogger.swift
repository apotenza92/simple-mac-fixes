import Foundation

enum RuntimeLogger {
    private static let queue = DispatchQueue(label: "Macsimize.RuntimeLogger")
    private static let environment = ProcessInfo.processInfo.environment
    private static let logFilePath = environment["MACSIMIZE_LOG_FILE"]
    private static let isEnabled = environment["MACSIMIZE_DEBUG_LOG"] == "1"
        || environment["MACSIMIZE_TEST_SUITE"] == "1"
        || logFilePath != nil

    static func log(_ message: String) {
        guard isEnabled else {
            return
        }

        let line = "[Macsimize] \(timestamp()) \(message)\n"
        fputs(line, stderr)

        guard let logFilePath else {
            return
        }

        queue.sync {
            let url = URL(fileURLWithPath: logFilePath)
            let data = Data(line.utf8)

            if FileManager.default.fileExists(atPath: logFilePath) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
