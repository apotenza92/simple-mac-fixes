import Foundation

/// The on/off fixes outside keyboard control. Volume and brightness keys keep
/// their own toggles from Simple Mac Keyboard Control.
public enum Feature: String, CaseIterable, Identifiable {
    case finderCut
    case mouseScrollReversal
    case greenButtonMaximize
    case dockWindowPreviews
    case dockFolderFinder
    case instantDock
    case instantSpaces
    case desktopShortcuts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .finderCut: "Cut and paste files"
        case .mouseScrollReversal: "Classic mouse wheel scrolling"
        case .greenButtonMaximize: "Maximize windows"
        case .instantSpaces: "Instant space switching"
        case .desktopShortcuts: "Space shortcuts"
        case .instantDock: "Instant Dock"
        case .dockWindowPreviews: "Window previews in the Dock"
        case .dockFolderFinder: "Open Dock folders in Finder"
        }
    }

    /// Plain language: what the person sees happen, with no system jargon.
    public var detail: String {
        switch self {
        case .finderCut:
            "Press Command-X to cut a file, then Command-V to move it to another folder."
        case .mouseScrollReversal:
            "Mice scroll in the traditional direction. Trackpads aren’t affected."
        case .greenButtonMaximize:
            "The green button makes a window fill the screen while keeping the Dock and menu bar. "
                + "Double-clicking the title bar does the same. Hold Option when clicking for full screen."
        case .dockWindowPreviews:
            "Point at an app in the Dock with more than one window to see them all, even minimized and hidden ones. "
                + "Click one to go to it, or scroll on the app to bring each one forward."
        case .dockFolderFinder:
            "Hold Option and click a folder in the Dock to open it in a Finder window."
        case .instantSpaces:
            "Moving between spaces with your keyboard shortcuts happens straight away, without the slide."
        case .desktopShortcuts:
            "Extra keyboard shortcuts for getting around your spaces."
        case .instantDock:
            "When the Dock is hidden, it appears as soon as you point at it."
        }
    }

    /// A fix that only works while another is on, shown under it.
    public var parent: Feature? {
        self == .desktopShortcuts ? .instantSpaces : nil
    }

    /// Shortcuts the fix adds, as keys to press and what they do, for listing under it.
    public var shortcuts: [(keys: [String], action: String)] {
        switch self {
        case .desktopShortcuts:
            [(["⌃", "⌥", "⌘", "1 – 9"], "Go to that space"),
             (["⌃", "⌥", "⌘", "Tab"], "Next space"),
             (["⌃", "⌥", "⌘", "~"], "Previous space")]
        default: []
        }
    }

    /// Spells out the key symbols used in `shortcuts`.
    public static let keyNames = "⌃ = Control   ⌥ = Option   ⌘ = Command\n"
        + "Together they're often known as Hyper key without Shift."

    /// Defaults should suit someone who just wants their Mac to behave. Changes to how
    /// the Dock and spaces feel, and new shortcuts that could clash with ones people
    /// already use, wait to be turned on.
    public var enabledByDefault: Bool {
        switch self {
        case .instantDock, .instantSpaces, .desktopShortcuts: false
        default: true
        }
    }

    /// Fixes that used to start on. Installs from before keep them as they were.
    public static let formerlyOnByDefault: [Feature] = [.instantDock, .instantSpaces, .desktopShortcuts]

    public var defaultsKey: String { "feature.\(rawValue).enabled" }

    public var conflictArea: ConflictingApp.Area {
        switch self {
        case .finderCut: .finderCut
        case .mouseScrollReversal: .mouseScrollReversal
        case .greenButtonMaximize: .greenButtonMaximize
        case .dockWindowPreviews, .dockFolderFinder: .dockClicks
        case .instantSpaces, .desktopShortcuts: .spaceSwitching
        case .instantDock: .dockHiding
        }
    }
}

/// Other utilities that would double up on a fix if both ran. They are quit
/// while the overlapping fix is on; Settings notes any that keep running.
public struct ConflictingApp: Equatable {
    public enum Area: Equatable {
        case finderCut, mouseScrollReversal, greenButtonMaximize, spaceSwitching, dockClicks, dockHiding, keyboardControl
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
        ConflictingApp(name: "InSpace", bundleIdentifier: "com.gameslayer999.inspace", area: .spaceSwitching),
        ConflictingApp(name: "Blink", bundleIdentifier: "com.thekoppe.Blink", area: .spaceSwitching),
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
