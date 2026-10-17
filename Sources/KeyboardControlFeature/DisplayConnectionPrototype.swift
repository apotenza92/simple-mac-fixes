import CoreGraphics
import Darwin
import Foundation

/// Development-only, bounded hardware experiment. Invoked before NSApplication
/// so a probe never starts a second audio pipeline or changes app preferences.
public enum DisplayConnectionPrototype {
    public static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--display-prototype" else { return false }
        guard Bundle.main.bundleIdentifier == "com.apotenza.SimpleMacFixes.dev" else {
            fputs("Display prototype requires the development app.\n", stderr)
            exit(2)
        }
        do {
            switch args.dropFirst().first {
            case "status":
                let data = try JSONEncoder().encode(DisplayConnection.screens())
                print(String(decoding: data, as: UTF8.self))
            case "guardian":
                guard args.count == 3 else { throw DisplayConnection.Failure(message: "Missing guardian target.") }
                try guardian(key: args[2])
            case "restore":
                guard args.count == 3 else { throw DisplayConnection.Failure(message: "Missing restore target.") }
                try DisplayConnection.restore(key: args[2])
                print("Restored and verified online.")
            case "cycle", "crash", "external-cycle", "external-crash", "unplug":
                try exercise(crash: args[1].hasSuffix("crash"), external: args[1].hasPrefix("external"), manual: args[1] == "unplug")
            default:
                throw DisplayConnection.Failure(message: "Use status, cycle, crash, external-cycle, external-crash, unplug, or restore KEY.")
            }
        } catch {
            fputs("Display prototype: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        return true
    }

    private static func guardian(key: String) throws {
        // The parent holds stdin open. EOF survives SIGKILL of the parent and
        // requires no scheduler, launch agent, privileges or saved preferences.
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        _ = FileHandle.standardInput.readDataToEndOfFile()
        let before = try? DisplayConnection.screens().first { $0.key == key }?.online
        fputs("Recovery: parent pipe closed; target online before restoration=\(String(describing: before)).\n", stderr)
        try DisplayConnection.restore(key: key)
        fputs("Recovery: target restored and verified online.\n", stderr)
    }

    private static func exercise(crash: Bool, external: Bool, manual: Bool) throws {
        #if !arch(arm64)
        throw DisplayConnection.Failure(message: "The first hardware prototype is limited to Apple silicon.")
        #else
        let screens = try DisplayConnection.screens()
        guard let target = screens.first(where: { $0.builtIn != external && $0.physical && $0.online }),
              DisplayConnection.disableError(target: target.key, screens: screens) == nil else {
            throw DisplayConnection.Failure(message: "Open the MacBook and attach an independent active external display first.")
        }
        let lease = try DisplayRecoveryLease(key: target.key)
        defer {
            lease.requestRestore()
            _ = lease.waitForExit()
        }
        let seconds: TimeInterval = manual ? 30 : 4
        let kind = external ? "external" : "built-in"
        print("Recovery armed. Disabled \(kind) display \(target.id) for up to \(Int(seconds)) seconds.")
        fflush(stdout)
        guard DisplayConnection.waitFor(key: target.key, online: false) else {
            throw DisplayConnection.Failure(message: "Display did not go offline.")
        }
        print("Verified \(kind) offline; surviving display active. Prototype PID=\(getpid()).")
        fflush(stdout)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if manual && !lease.process.isRunning {
                guard DisplayConnection.waitFor(key: target.key, online: true) else {
                    throw DisplayConnection.Failure(message: "Physical recovery did not restore the built-in screen.")
                }
                print("Independent recovery completed before the time limit; reconnect the external display.")
                return
            }
            let current = try DisplayConnection.screens()
            guard manual || current.contains(where: { $0.key != target.key && $0.active && $0.online }) else {
                throw DisplayConnection.Failure(message: "Surviving display lost; restoring built-in immediately.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if manual { print("Time limit reached; restoring. No physical recovery event was observed.") }
        if crash {
            print("Killing prototype process to exercise independent recovery.")
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }
        lease.requestRestore()
        guard lease.waitForExit(), DisplayConnection.waitFor(key: target.key, online: true) else {
            throw DisplayConnection.Failure(message: "Recovery did not finish.")
        }
        print("Cycle passed: \(kind) restored and verified online.")
        #endif
    }
}
