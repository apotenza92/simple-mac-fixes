public enum UpdateCheckSchedule: String, CaseIterable, Identifiable {
    case startup, daily, weekly, monthly, never
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .startup: return "On startup"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .never: return "Never"
        }
    }
    /// Startup checks retain a weekly background check for long-running sessions.
    public var interval: Double {
        switch self {
        case .daily: return 86400
        case .monthly: return 30 * 86400
        case .startup, .weekly, .never: return 7 * 86400
        }
    }
    public static func resolve(saved: String?, bundleIdentifier: String?, automaticChecksEnabled: Bool) -> Self {
        guard automaticChecksEnabled else { return .never }
        if let saved, let schedule = Self(rawValue: saved), schedule != .never { return schedule }
        return bundleIdentifier == "com.apotenza.SimpleMacFixes.beta" ? .startup : .weekly
    }
}
