import ApplicationServices
import CoreGraphics
import Foundation

/// Facts about the displays that decide where an on-screen overlay belongs.
public enum DisplayPlacement {
    /// Whether the given display is showing a full-screen app right now.
    public static func isFullScreenShowing(on display: CGDirectDisplayID) -> Bool {
        guard let entries = SkyLight.managedDisplaySpaces(),
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(nil, uuid) as String? else { return false }
        return isFullScreenShowing(onDisplayIdentifier: identifier, in: entries)
    }

    static func isFullScreenShowing(onDisplayIdentifier identifier: String, in entries: [[String: Any]]) -> Bool {
        // With "Displays have separate Spaces" off there is a single entry named "Main".
        let entry = entries.first {
            ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(identifier) == .orderedSame
        } ?? (entries.count == 1 ? entries[0] : nil)
        // Type 0 is a desktop; 4 is a full-screen app.
        return (entry?["Current Space"] as? [String: Any])?["type"] as? Int == 4
    }

    /// The display whose menu bar holds an item. Displays stacked above one another share
    /// the same horizontal range, so the one whose top edge is nearest wins. Frames are in
    /// global top-left coordinates, as `CGDisplayBounds` and Accessibility report them.
    public static func screen(forMenuBarItem frame: CGRect, among screens: [CGRect]) -> CGRect? {
        screens
            .filter { $0.minX <= frame.midX && frame.midX < $0.maxX }
            .min { abs($0.minY - frame.midY) < abs($1.minY - frame.midY) }
    }
}
