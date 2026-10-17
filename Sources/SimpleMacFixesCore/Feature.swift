import Foundation

/// The on/off fixes outside keyboard control. Volume and brightness keys keep
/// their own toggles from Simple Mac Keyboard Control.
public enum Feature: String, CaseIterable, Identifiable {
    case finderCut
    case mouseScrollReversal
    case greenButtonMaximize
    case dockAppExpose

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .finderCut: "Cut and paste files in Finder"
        case .mouseScrollReversal: "Traditional mouse scrolling"
        case .greenButtonMaximize: "Maximize windows"
        case .dockAppExpose: "Dock shows app windows"
        }
    }

    public var detail: String {
        switch self {
        case .finderCut: "⌘X then ⌘V moves files. Text fields are unchanged."
        case .mouseScrollReversal: "Wheel mice scroll like Windows. Trackpads and the Magic Mouse follow System Settings."
        case .greenButtonMaximize: "The green button or a title-bar double-click fills the screen without full screen. Drag the title bar to restore. Option-click the green button for full screen."
        case .dockAppExpose: "Clicking an app in the Dock that has more than one window shows them with App Exposé."
        }
    }

    /// Defaults should suit someone who just wants their Mac to behave.
    public var enabledByDefault: Bool { true }

    public var defaultsKey: String { "feature.\(rawValue).enabled" }

    public var conflictArea: ConflictingApp.Area {
        switch self {
        case .finderCut: .finderCut
        case .mouseScrollReversal: .mouseScrollReversal
        case .greenButtonMaximize: .greenButtonMaximize
        case .dockAppExpose: .dockClicks
        }
    }
}

/// Other utilities that would double up on a fix if both ran.
public struct ConflictingApp: Equatable {
    public enum Area: Equatable {
        case finderCut, mouseScrollReversal, greenButtonMaximize, dockClicks, keyboardControl
    }

    public let name: String
    public let bundleIdentifier: String
    public let area: Area

    public static let known: [ConflictingApp] = [
        ConflictingApp(name: "LinearMouse", bundleIdentifier: "com.lujjjh.LinearMouse", area: .mouseScrollReversal),
        ConflictingApp(name: "Scroll Reverser", bundleIdentifier: "com.pilotmoon.scroll-reverser", area: .mouseScrollReversal),
        ConflictingApp(name: "Mos", bundleIdentifier: "com.caldis.Mos", area: .mouseScrollReversal),
        ConflictingApp(name: "UnnaturalScrollWheels", bundleIdentifier: "com.theron.UnnaturalScrollWheels", area: .mouseScrollReversal),
        ConflictingApp(name: "Command X", bundleIdentifier: "com.sindresorhus.Command-X", area: .finderCut),
        ConflictingApp(name: "Macsimize", bundleIdentifier: "pzc.Macsimize", area: .greenButtonMaximize),
        ConflictingApp(name: "Dockmint", bundleIdentifier: "pzc.Dockmint", area: .dockClicks),
        ConflictingApp(name: "Docktor", bundleIdentifier: "pzc.Docktor", area: .dockClicks),
        ConflictingApp(name: "DockDoor", bundleIdentifier: "com.ethanbills.DockDoor", area: .dockClicks),
        ConflictingApp(name: "Simple Mac Keyboard Control", bundleIdentifier: "com.apotenza.KeyControl", area: .keyboardControl),
    ]

    /// Matches beta and development builds of the same app too.
    public static func conflicts(in area: Area, runningBundleIdentifiers: [String]) -> [ConflictingApp] {
        known.filter { app in
            app.area == area && runningBundleIdentifiers.contains {
                $0.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame
                    || $0.lowercased().hasPrefix(app.bundleIdentifier.lowercased() + ".")
            }
        }
    }
}
