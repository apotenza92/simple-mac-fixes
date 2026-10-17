import Darwin
import Foundation

/// Small pipe protocol used only between this app and its own signed executable.
/// A child owns each disconnect, so closing the parent pipe always requests
/// restoration even when applicationWillTerminate never runs.
enum DisplayRecoveryProtocol {
    static func readLine(_ handle: FileHandle, timeout: TimeInterval) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = Data()
        while bytes.count < 1024 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DisplayConnection.Failure(message: "Display recovery process timed out.") }
            var fd = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&fd, 1, Int32(min(remaining * 1000, 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw DisplayConnection.Failure(message: "Could not read display recovery response.") }
            if result == 0 { continue }
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else { throw DisplayConnection.Failure(message: "Display recovery process stopped unexpectedly.") }
            if byte == Data([10]) { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw DisplayConnection.Failure(message: "Invalid display recovery response.")
    }
}

/// Queue-confined owner. Closing stdin is a restore request, never an immediate
/// kill of the process responsible for putting a screen back.
final class DisplayRecoveryLease {
    let process = Process()
    let key: String
    private let input = Pipe()
    private let output = Pipe()
    private var closed = false

    init(key: String) throws {
        self.key = key
        guard let executable = Bundle.main.executableURL else { throw DisplayConnection.Failure(message: "Missing application executable.") }
        process.executableURL = executable
        process.arguments = ["--display-recovery", key]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        do {
            guard try DisplayRecoveryProtocol.readLine(output.fileHandleForReading, timeout: 5) == "ready" else {
                throw DisplayConnection.Failure(message: "Display recovery could not be armed.")
            }
            try input.fileHandleForWriting.write(contentsOf: Data("disable\n".utf8))
            let response = try DisplayRecoveryProtocol.readLine(output.fileHandleForReading, timeout: 8)
            guard response == "disabled" else { throw DisplayConnection.Failure(message: response) }
        } catch {
            requestRestore()
            // Also leave the independent process alive if macOS is slow.
            _ = waitForExit(seconds: 8)
            throw error
        }
    }

    func requestRestore() {
        guard !closed else { return }
        closed = true
        input.fileHandleForWriting.closeFile()
    }

    func waitForExit(seconds: TimeInterval = 8) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !process.isRunning
    }

    deinit { requestRestore() }
}

public enum DisplayRecoveryProcess {
    /// Run before initializing AppKit, Sparkle, audio or preferences.
    public static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--display-recovery" else { return false }
        guard args.count == 2 else { exit(2) }
        do {
            try run(key: args[1])
        } catch {
            fputs("Display recovery: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        return true
    }

    private static func run(key: String) throws {
        let initial = try DisplayConnection.screens()
        if let error = DisplayConnection.disableError(target: key, screens: initial) { throw DisplayConnection.Failure(message: error) }
        let target = initial.first { $0.key == key }!
        let transportIDs = Set(try DisplayHardware.transports().map(\.registryID))
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        guard try DisplayRecoveryProtocol.readLine(.standardInput, timeout: 5) == "disable" else {
            throw DisplayConnection.Failure(message: "Invalid display recovery request.")
        }
        do {
            try DisplayConnection.setEnabled(false, key: key)
            guard DisplayConnection.waitFor(key: key, online: false) else {
                throw DisplayConnection.Failure(message: "macOS did not disable the display.")
            }
            FileHandle.standardOutput.write(Data("disabled\n".utf8))
            while true {
                var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let result = poll(&fd, 1, 500)
                if result < 0 && errno == EINTR { continue }
                // Any input, EOF, descriptor error, or HUP asks us to restore.
                if result != 0 {
                    fputs("Recovery: parent pipe closed or restore requested.\n", stderr)
                    break
                }
                let currentIDs = Set(try DisplayHardware.transports().map(\.registryID))
                if !transportIDs.isSubset(of: currentIDs) {
                    fputs("Recovery: physical display connection lost.\n", stderr)
                    break
                }
                if try DisplayConnection.screens().first(where: { $0.key == key })?.online == true {
                    // macOS or the user re-enabled it; never fight that change.
                    fputs("Recovery: display is already online.\n", stderr)
                    return
                }
            }
        } catch {
            try? DisplayConnection.restore(key: key)
            throw error
        }
        let current = try DisplayConnection.screens().first { $0.key == key }
        fputs("Recovery: target online before restoration=\(String(describing: current?.online)).\n", stderr)
        // Try restoring even when a transport disappeared: sleep or a driver
        // reset can look like cable removal. Only tolerate failure when the
        // external hardware is still absent; the parent retains recovery intent.
        do { try DisplayConnection.restore(key: key) }
        catch {
            if !target.builtIn, try DisplayConnection.screens().first(where: { $0.key == key })?.physical != true {
                fputs("Recovery: external hardware absent; parent will retry on reconnect.\n", stderr)
                return
            }
            throw error
        }
        fputs("Recovery: target restored and verified online.\n", stderr)
    }
}
