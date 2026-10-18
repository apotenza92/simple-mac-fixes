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

    /// Generous enough for tall unified toolbars; title bars sit inside it.
    static let topBandHeight: CGFloat = 120

    /// `windows` is front to back, in the same top-left coordinates as mouse events.
    static func mayContainWindowControls(at point: CGPoint, windows: [Window]) -> Bool {
        guard let window = windows.first(where: { $0.alpha > 0.01 && $0.bounds.contains(point) }) else {
            return false
        }
        // Menus, popovers (such as the green button's tile menu), the Dock and overlays.
        guard window.layer == 0 else { return false }
        return point.y - window.bounds.minY <= topBandHeight
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
