import Foundation

/// The on/off fixes outside keyboard control. Volume and brightness keys keep
/// their own toggles from Simple Mac Keyboard Control.
public enum Feature: String, CaseIterable, Identifiable {
    case finderCut
    case mouseScrollReversal
    case greenButtonMaximize
    case dockAppExpose
    case dockFolderFinder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .finderCut: "Cut and paste files in Finder"
        case .mouseScrollReversal: "Traditional mouse scrolling"
        case .greenButtonMaximize: "Maximize windows"
        case .dockAppExpose: "Dock shows app windows"
        case .dockFolderFinder: "Option-click Dock folders opens Finder"
        }
    }

    public var detail: String {
        switch self {
        case .finderCut: "⌘X then ⌘V moves files. Text fields are unchanged."
        case .mouseScrollReversal: "Wheel mice scroll like Windows. Trackpads and the Magic Mouse follow System Settings."
        case .greenButtonMaximize: "The green button or a title-bar double-click fills the screen without full screen. Drag the title bar to restore. Option-click the green button for full screen."
        case .dockAppExpose: "Clicking an app in the Dock that has more than one window shows them with App Exposé."
        case .dockFolderFinder: "Option-click a folder in the Dock to open it in Finder instead of the stack."
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
        case .dockAppExpose, .dockFolderFinder: .dockClicks
        }
    }
}

/// Other utilities that would double up on a fix if both ran. They are quit
/// while the overlapping fix is on; the menu notes any that keep running.
public struct ConflictingApp: Equatable {
    public enum Area: Equatable {
        case finderCut, mouseScrollReversal, greenButtonMaximize, dockClicks, keyboardControl
    }

    public let name: String
    public let bundleIdentifier: String
    public let area: Area
    /// One of the apps Simple Mac Fixes replaces; it is quit whenever both run.
    public var isReplaced = false

    public static let known: [ConflictingApp] = [
        ConflictingApp(name: "LinearMouse", bundleIdentifier: "com.lujjjh.LinearMouse", area: .mouseScrollReversal),
        ConflictingApp(name: "Scroll Reverser", bundleIdentifier: "com.pilotmoon.scroll-reverser", area: .mouseScrollReversal),
        ConflictingApp(name: "Mos", bundleIdentifier: "com.caldis.Mos", area: .mouseScrollReversal),
        ConflictingApp(name: "UnnaturalScrollWheels", bundleIdentifier: "com.theron.UnnaturalScrollWheels", area: .mouseScrollReversal),
        ConflictingApp(name: "Command X", bundleIdentifier: "com.sindresorhus.Command-X", area: .finderCut),
        ConflictingApp(name: "Macsimize", bundleIdentifier: "pzc.Macsimize", area: .greenButtonMaximize, isReplaced: true),
        ConflictingApp(name: "Dockmint", bundleIdentifier: "pzc.Dockmint", area: .dockClicks, isReplaced: true),
        ConflictingApp(name: "Docktor", bundleIdentifier: "pzc.Docktor", area: .dockClicks, isReplaced: true),
        ConflictingApp(name: "DockDoor", bundleIdentifier: "com.ethanbills.DockDoor", area: .dockClicks),
        ConflictingApp(name: "Simple Mac Keyboard Control", bundleIdentifier: "com.apotenza.KeyControl", area: .keyboardControl, isReplaced: true),
    ]

    /// Matches beta and development builds of the same app too.
    public func matches(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.caseInsensitiveCompare(self.bundleIdentifier) == .orderedSame
            || bundleIdentifier.lowercased().hasPrefix(self.bundleIdentifier.lowercased() + ".")
    }

    public static func conflicts(in area: Area, runningBundleIdentifiers: [String]) -> [ConflictingApp] {
        known.filter { app in
            app.area == area && !app.isReplaced && runningBundleIdentifiers.contains(where: app.matches)
        }
    }

    /// The old apps this one replaces, which should be quit rather than warned about.
    public static func isReplaced(_ bundleIdentifier: String) -> Bool {
        known.contains { $0.isReplaced && $0.matches(bundleIdentifier) }
    }
}
