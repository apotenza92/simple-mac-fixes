import CoreGraphics
import Foundation

/// A keyboard shortcut that moves between desktops.
public struct SpaceShortcut: Equatable {
    public enum Action: Equatable {
        case left, right
        /// Like left and right, but wrapping around at the ends.
        case next, previous
        /// Desktop N as Mission Control numbers them, zero-based.
        case desktop(Int)
    }

    public let keyCode: Int64
    public let modifiers: CGEventFlags
    public let action: Action

    public static func == (lhs: SpaceShortcut, rhs: SpaceShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers && lhs.action == rhs.action
    }
}

/// The system's own "Move left/right a space" shortcuts, read live so the same
/// keys switch instantly, plus Control-Option-Command-1…9 to jump to a desktop
/// and Control-Option-Command-Tab and -` to cycle through every space.
///
/// The system's "Switch to Desktop N" shortcuts are left alone: macOS only
/// offers them for desktops that already exist. Its settings are never changed.
public enum SpaceShortcuts {
    public static let modifierMask: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
    private static let leftIDs = [79, 80], rightIDs = [81, 82]
    private static let noKey: Int64 = 65535

    /// Control-Option-Command and 1 to 9 on the number row.
    public static let jumpModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    private static let numberRowKeyCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    public static let desktopJumps: [SpaceShortcut] = numberRowKeyCodes.enumerated().map {
        SpaceShortcut(keyCode: $0.element, modifiers: jumpModifiers, action: .desktop($0.offset))
    } + [
        SpaceShortcut(keyCode: 48, modifiers: jumpModifiers, action: .next),     // Tab
        SpaceShortcut(keyCode: 50, modifiers: jumpModifiers, action: .previous), // ` (the ~ key)
    ]

    /// The system's own defaults when a shortcut has never been changed: ⌃← and ⌃→.
    private static let defaults: [Int: (keyCode: Int64, modifiers: CGEventFlags)] = [
        79: (123, .maskControl), 81: (124, .maskControl),
    ]

    /// The system's left and right shortcuts and, separately, this app's own desktop shortcuts.
    public static func current(system: Bool, jumps: Bool) -> [SpaceShortcut] {
        var shortcuts: [SpaceShortcut] = []
        if system {
            let domain = "com.apple.symbolichotkeys" as CFString
            CFPreferencesAppSynchronize(domain)
            shortcuts = parse(CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any])
        }
        // The system's own shortcuts come first if someone has given one the same keys.
        return shortcuts + (jumps ? desktopJumps : [])
    }

    /// The system's move-left and move-right shortcuts. `hotKeys` is the
    /// `AppleSymbolicHotKeys` dictionary, keyed by shortcut ID.
    public static func parse(_ hotKeys: [String: Any]?) -> [SpaceShortcut] {
        var shortcuts: [SpaceShortcut] = []
        for id in leftIDs + rightIDs {
            let action: SpaceShortcut.Action = leftIDs.contains(id) ? .left : .right
            guard let entry = hotKeys?[String(id)] as? [String: Any] else {
                if let fallback = defaults[id] {
                    shortcuts.append(SpaceShortcut(keyCode: fallback.keyCode, modifiers: fallback.modifiers, action: action))
                }
                continue
            }
            guard (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { continue }
            let keyCode = parameters[1].int64Value
            guard keyCode != noKey else { continue }
            // The saved modifier bits match CGEventFlags; anything else (such as the
            // arrow keys' function-key bit) is ignored.
            let modifiers = CGEventFlags(rawValue: parameters[2].uint64Value).intersection(modifierMask)
            shortcuts.append(SpaceShortcut(keyCode: keyCode, modifiers: modifiers, action: action))
        }
        return shortcuts
    }

    public static func match(keyCode: Int64, flags: CGEventFlags, in shortcuts: [SpaceShortcut]) -> SpaceShortcut? {
        let modifiers = flags.intersection(modifierMask)
        return shortcuts.first { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }
}
