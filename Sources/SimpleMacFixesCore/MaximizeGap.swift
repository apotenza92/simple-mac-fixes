import Foundation

/// The space a maximized window leaves to the edges of its screen, in points.
/// The system leaves 8 points around a window it fills when its own margins are on.
public enum MaximizeGap: Int, CaseIterable, Sendable {
    case off = 0
    case small = 8
    case medium = 16
    case large = 32

    public static let defaultsKey = "maximizeGap"

    public var title: String {
        switch self {
        case .off: "Off"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The saved choice. A value that is no choice counts as off.
    public static func resolve(saved: Int?) -> MaximizeGap {
        saved.flatMap(MaximizeGap.init(rawValue:)) ?? .off
    }
}
