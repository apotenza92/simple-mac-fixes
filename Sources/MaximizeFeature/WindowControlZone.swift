import CoreGraphics
import Foundation

/// A cheap check, before any accessibility query, that a click could reach a
/// window's title bar or green button.
///
/// Accessibility queries go to the app under the pointer and the click waits
/// for the answer; a busy app can hold every click on the Mac for seconds. The
/// window list comes from the window server, which always answers quickly.
enum WindowControlZone {
    struct Window: Equatable {
        let bounds: CGRect
        let layer: Int
        let alpha: Double
    }

    enum Region: Equatable {
        /// The top-left corner, where the close, minimize and green buttons sit.
        case windowButtons
        /// The rest of the band along the top, where the title bar is.
        case titleBar
    }

    /// Generous enough for tall unified toolbars; title bars sit inside it.
    static let topBandHeight: CGFloat = 120
    /// Holds the buttons in tall toolbars and in apps that move them inward.
    static let buttonsCorner = CGSize(width: 110, height: 60)

    /// `windows` is front to back and `displays` are the screens' bounds, all in the
    /// same top-left coordinates as mouse events.
    ///
    /// A window covering a whole screen is skipped: the Dock and screen overlays keep
    /// one up, see-through and letting clicks past, in front of every window. A
    /// full-screen app's window is skipped with them, which is harmless: it has no
    /// title bar, and its green button is left alone anyway.
    static func region(at point: CGPoint, windows: [Window], displays: [CGRect]) -> Region? {
        let screen = displays.first { $0.contains(point) }
        guard let window = windows.first(where: {
            $0.alpha > 0.01 && $0.bounds.contains(point) && !(screen.map($0.bounds.contains) ?? false)
        }) else {
            return nil
        }
        // Menus, popovers (such as the green button's tile menu), the Dock and overlays.
        guard window.layer == 0 else { return nil }
        let offset = CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY)
        guard offset.y <= topBandHeight else { return nil }
        return offset.x <= buttonsCorner.width && offset.y <= buttonsCorner.height ? .windowButtons : .titleBar
    }

    static func mayContainWindowControls(at point: CGPoint, windows: [Window], displays: [CGRect] = []) -> Bool {
        region(at: point, windows: windows, displays: displays) != nil
    }

    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    static func onScreenWindows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return Window(bounds: bounds,
                          layer: info[kCGWindowLayer as String] as? Int ?? 0,
                          alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}
