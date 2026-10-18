import Foundation

/// Makes a hidden Dock appear the moment the pointer reaches it, only while
/// Simple Mac Fixes runs. The Dock's own settings are restored on quit, when
/// the switch is turned off, and on the next launch after a crash.
public final class InstantDockFeature {
    /// The Dock settings this changes, and the instant value of each.
    static let instantValues: [(key: String, value: NSNumber)] = [
        ("autohide-delay", NSNumber(value: 0.0)),
        ("autohide-time-modifier", NSNumber(value: 0)),
    ]

    private let defaults: UserDefaults
    private let dockDomain: CFString
    private let restartDock: () -> Void
    private static let savedKey = "instantDock.savedDockSettings"

    /// Tests pass their own `dockDomain` so they never touch the real Dock.
    public init(defaults: UserDefaults = .standard, dockDomain: String = "com.apple.dock",
                restartDock: @escaping () -> Void = InstantDockFeature.restartDock) {
        self.defaults = defaults
        self.dockDomain = dockDomain as CFString
        self.restartDock = restartDock
    }

    /// True once the instant values are in place and the originals are saved.
    public var isApplied: Bool { defaults.dictionary(forKey: Self.savedKey) != nil }

    public func apply() {
        guard !isApplied else { return }
        // Save what was there; a missing key restores to the system default.
        var saved: [String: Any] = [:]
        for (key, _) in Self.instantValues {
            if let value = CFPreferencesCopyAppValue(key as CFString, dockDomain) { saved[key] = value }
        }
        defaults.set(saved, forKey: Self.savedKey)
        let changed = Self.instantValues.contains { saved[$0.key] as? NSNumber != $0.value }
        for (key, value) in Self.instantValues {
            CFPreferencesSetAppValue(key as CFString, value, dockDomain)
        }
        CFPreferencesAppSynchronize(dockDomain)
        if changed { restartDock() }
    }

    public func restore() {
        guard let saved = defaults.dictionary(forKey: Self.savedKey) else { return }
        var changed = false
        for (key, instant) in Self.instantValues {
            let original = saved[key] as CFPropertyList?
            // Leave it alone if someone set a different value meanwhile.
            guard CFPreferencesCopyAppValue(key as CFString, dockDomain) as? NSNumber == instant,
                  original as? NSNumber != instant else { continue }
            CFPreferencesSetAppValue(key as CFString, original, dockDomain)
            changed = true
        }
        CFPreferencesAppSynchronize(dockDomain)
        defaults.removeObject(forKey: Self.savedKey)
        if changed { restartDock() }
    }

    /// The Dock reads these settings only when it starts; it relaunches itself.
    public static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
        process.waitUntilExit()
    }
}
