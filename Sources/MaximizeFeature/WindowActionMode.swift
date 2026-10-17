import Foundation

enum WindowActionMode: String, CaseIterable, Codable, Identifiable {
    case maximize
    case fullScreen

    var id: String { rawValue }

    var opposite: Self {
        switch self {
        case .maximize:
            return .fullScreen
        case .fullScreen:
            return .maximize
        }
    }

    var displayName: String {
        switch self {
        case .maximize:
            return AppStrings.maximizeModeTitle
        case .fullScreen:
            return AppStrings.fullScreenModeTitle
        }
    }

    var helpText: String {
        switch self {
        case .maximize:
            return AppStrings.maximizeModeHelp
        case .fullScreen:
            return AppStrings.fullScreenModeHelp
        }
    }

    var isExperimental: Bool {
        false
    }
}
