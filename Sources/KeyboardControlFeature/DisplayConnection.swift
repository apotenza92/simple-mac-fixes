import CoreGraphics
import Foundation

/// The private display-connection API is isolated from brightness and audio.
/// All callers must serialize transactions and arrange independent recovery.
enum DisplayConnection {
    struct Screen: Codable, Equatable {
        let id: CGDirectDisplayID
        let key: String
        let builtIn: Bool
        let online: Bool
        let active: Bool
        let mirrored: Bool
        let vendor: UInt32
        let model: UInt32
        var physical: Bool = true
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private typealias ListFunction = @convention(c)
        (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    private typealias EnableFunction = @convention(c)
        (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    private static func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return names.lazy.compactMap { dlsym(handle, $0) }.first
    }
    private static let listFunction = symbol(["CGSGetDisplayList", "SLSGetDisplayList"])
        .map { unsafeBitCast($0, to: ListFunction.self) }
    private static let enableFunction = symbol(["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"])
        .map { unsafeBitCast($0, to: EnableFunction.self) }

    static var isAvailable: Bool {
        #if arch(arm64)
        return listFunction != nil && enableFunction != nil
        #else
        return false
        #endif
    }

    static func key(builtIn: Bool, vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        builtIn ? "builtin:\(vendor):\(model)" : "external:\(vendor):\(model):\(serial)"
    }

    static func screens() throws -> [Screen] {
        guard let listFunction else { throw Failure(message: "Display connection control is unavailable on this macOS version.") }
        let transports = (try? DisplayHardware.transports()) ?? []
        var capacity: UInt32 = 16
        while capacity <= 4096 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
            var count: UInt32 = 0
            let result = listFunction(capacity, &ids, &count)
            guard result == .success else { throw Failure(message: "Could not read displays (\(result.rawValue)).") }
            if count >= capacity { capacity *= 2; continue }
            return ids.prefix(Int(count)).compactMap { id in
                // WindowServer also enumerates stale entries with no hardware identity.
                let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
                guard vendor != 0 || model != 0 else { return nil }
                let builtIn = CGDisplayIsBuiltin(id) != 0
                let serial = CGDisplaySerialNumber(id)
                // UUID lookup disappears for software-disabled screens on macOS
                // 27. Hardware fields remain available. Duplicate keys are
                // deliberately not switchable; never guess between identical
                // monitors with no distinguishing serial number.
                let physical = builtIn || transports.contains {
                    $0.vendor == vendor && $0.model == model && ($0.serial == serial || serial == 0 || $0.serial == 0)
                }
                return Screen(id: id, key: key(builtIn: builtIn, vendor: vendor, model: model, serial: serial), builtIn: builtIn,
                              online: CGDisplayIsOnline(id) != 0, active: CGDisplayIsActive(id) != 0,
                              mirrored: CGDisplayIsInMirrorSet(id) != 0, vendor: vendor, model: model, physical: physical)
            }
        }
        throw Failure(message: "Display enumeration exceeded its safety limit.")
    }

    /// Pure preflight used again immediately before a transaction, not just by UI.
    static func disableError(target: String, screens: [Screen]) -> String? {
        let matches = screens.filter { $0.key == target }
        guard matches.count == 1, let screen = matches.first else { return "The display identity is missing or ambiguous." }
        guard screen.online && screen.active else { return "The display is not active." }
        guard screen.physical else { return "This display connection cannot be verified for switching." }
        // A mirror set is not evidence of an independent surviving desktop.
        guard !screen.mirrored else { return "Turn off display mirroring before disabling this display." }
        guard screens.contains(where: { $0.key != target && $0.physical && $0.online && $0.active && !$0.mirrored }) else {
            return "At least one other active display must remain enabled."
        }
        return nil
    }

    static func setEnabled(_ enabled: Bool, key: String) throws {
        guard let enableFunction else { throw Failure(message: "Display connection control is unavailable.") }
        let current = try screens()
        if !enabled, !isAvailable { throw Failure(message: "Display switching is currently supported on Apple silicon only.") }
        if !enabled, let message = disableError(target: key, screens: current) { throw Failure(message: message) }
        let matches = current.filter { $0.key == key }
        guard matches.count == 1, let target = matches.first else {
            throw Failure(message: "The display identity is missing or ambiguous.")
        }
        if target.online == enabled { return }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw Failure(message: "Could not begin display change (\(begin.rawValue)).") }
        let set = enableFunction(config, target.id, enabled)
        guard set == .success else {
            CGCancelDisplayConfiguration(config)
            throw Failure(message: "macOS rejected the display change (\(set.rawValue)).")
        }
        // Never persist a disabled display across login/reboot. This option alone
        // is NOT assumed to recover private enable state when the process dies.
        let complete = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard complete == .success else { throw Failure(message: "Could not apply display change (\(complete.rawValue)).") }
    }

    static func waitFor(key: String, online: Bool, seconds: TimeInterval = 3) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if let screen = try? screens().first(where: { $0.key == key }), screen.online == online { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    static func restore(key: String) throws {
        var last: Error = Failure(message: "Display restoration did not complete.")
        for _ in 0..<5 {
            do {
                try setEnabled(true, key: key)
                if waitFor(key: key, online: true, seconds: 0.5) { return }
            } catch { last = error }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw last
    }
}
