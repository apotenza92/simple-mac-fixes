import Foundation

/// Desired software levels outlive temporary display IDs and disconnections.
struct SoftwareBrightnessMemory {
    let defaults: UserDefaults
    private let preference = "softwareBrightnessByDisplay"

    static func key(vendor: UInt32, model: UInt32, serial: UInt32) -> String? {
        // A model alone cannot distinguish two identical monitors.
        guard vendor != 0, model != 0, serial != 0 else { return nil }
        return "\(vendor):\(model):\(serial)"
    }

    func level(for key: String?) -> Int? {
        guard let key, let value = defaults.dictionary(forKey: preference)?[key] as? Int else { return nil }
        return Level.clamp(value)
    }

    func remember(_ value: Int, for key: String?) {
        guard let key else { return }
        var levels = defaults.dictionary(forKey: preference) ?? [:]
        levels[key] = Level.clamp(value)
        defaults.set(levels, forKey: preference)
    }
}
