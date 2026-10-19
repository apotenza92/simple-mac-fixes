import AppKit
import ApplicationServices

/// One of an app's windows, wherever it is: this desktop, another desktop,
/// minimized, or belonging to a hidden app.
public struct DockWindow: Identifiable, Equatable {
    public enum Place: Equatable {
        case here
        case otherDesktop(number: Int?, spaceID: UInt64)
        case minimized
        case hidden
    }

    public let id: CGWindowID
    public let processIdentifier: pid_t
    public let title: String
    public let place: Place
    let bounds: CGRect
}

/// Finds every window worth showing for an app. Safe off the main thread.
///
/// The app's accessibility window list covers this desktop, minimized windows
/// and hidden apps, including small windows such as Settings that Mission
/// Control leaves out. Windows on other desktops come from the window server.
enum DockWindows {
    /// Smaller than this is a palette, tooltip or invisible helper window.
    static let minimumSize = CGSize(width: 120, height: 80)
    private static let ignoredSubroles: Set<String> = ["AXUnknown", "AXSystemDialog"]

    static func windows(bundleIdentifier: String) -> [DockWindow] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !apps.isEmpty else { return [] }
        let pids = Set(apps.map(\.processIdentifier))
        let hidden = apps.contains(where: \.isHidden)

        // Every desktop's windows, with sizes and window-server titles. This list isn't
        // in front-to-back order; the on-screen list below is.
        let entries = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).filter {
            pids.contains(($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        var order: [CGWindowID: Int] = [:]
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { entry -> CGWindowID? in
            guard pids.contains((entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0) else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        for (index, id) in onScreen.enumerated() { order[id] = index }
        var info: [CGWindowID: (bounds: CGRect, title: String, alpha: Double)] = [:]
        for (index, entry) in entries.enumerated() {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { continue }
            if order[id] == nil { order[id] = onScreen.count + index }
            info[id] = (bounds, entry[kCGWindowName as String] as? String ?? "",
                        entry[kCGWindowAlpha as String] as? Double ?? 1)
        }

        var result: [DockWindow] = []
        var seen = Set<CGWindowID>()
        for app in apps {
            for window in axWindows(of: app.processIdentifier) {
                guard let id = WindowSpacePrivateApis.windowID(for: window), seen.insert(id).inserted else { continue }
                let subrole = string(window, kAXSubroleAttribute)
                guard !ignoredSubroles.contains(subrole ?? ""),
                      let bounds = info[id]?.bounds ?? frame(of: window), isBigEnough(bounds) else { continue }
                let minimized = (copy(window, kAXMinimizedAttribute) as? Bool) == true
                let title = string(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? info[id]?.title ?? ""
                result.append(DockWindow(id: id, processIdentifier: app.processIdentifier, title: title,
                                         place: minimized ? .minimized : hidden ? .hidden : .here, bounds: bounds))
            }
        }

        // Windows on other desktops never appear in the accessibility list.
        let visibleSpaces = Set(WindowSpacePrivateApis.activeSpaceIDs().map { Int($0) })
        let desktops = WindowSpacePrivateApis.desktopNumbers()
        for entry in entries {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !seen.contains(id),
                  let window = info[id], window.alpha > 0.01, isBigEnough(window.bounds) else { continue }
            let spaces = WindowSpacePrivateApis.spaces(for: id)
            // No space means a helper window that is never shown.
            guard let space = spaces.first, spaces.isDisjoint(with: visibleSpaces) else { continue }
            seen.insert(id)
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let place: DockWindow.Place = hidden
                ? .hidden : .otherDesktop(number: desktops[UInt64(space)], spaceID: UInt64(space))
            result.append(DockWindow(id: id, processIdentifier: pid, title: window.title, place: place, bounds: window.bounds))
        }
        // Most recent first: windows here front to back, then those on other desktops,
        // then minimized and hidden ones, each group in the window server's order.
        func group(_ window: DockWindow) -> Int {
            switch window.place {
            case .here: 0
            case .otherDesktop: 1
            case .minimized: 2
            case .hidden: 3
            }
        }
        return result.sorted {
            (group($0), order[$0.id] ?? .max) < (group($1), order[$1.id] ?? .max)
        }
    }

    enum Control { case close, minimize, maximize }

    /// The traffic-light buttons, done through accessibility. Windows on other
    /// desktops have no accessibility element, so they offer no controls.
    static func perform(_ control: Control, on window: DockWindow) {
        guard let element = element(for: window) else { return }
        switch control {
        case .close:
            if let button = copy(element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        case .minimize:
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case .maximize:
            toggleFullScreen(element)
        }
    }

    /// The green button's own behaviour: into full screen, or back out of it.
    static func toggleFullScreen(_ element: AXUIElement) {
        let isFullScreen = (copy(element, "AXFullScreen") as? Bool) ?? false
        let error = AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, (!isFullScreen) as CFBoolean)
        if error != .success, let button = copy(element, kAXFullScreenButtonAttribute) {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// The usable part of the screen holding most of `bounds`, in top-left coordinates.
    private static func screenFrame(containing bounds: CGRect) -> CGRect? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frames = NSScreen.screens.map { screen -> CGRect in
            let visible = screen.visibleFrame
            return CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
        }
        return frames.max { $0.intersection(bounds).area < $1.intersection(bounds).area }
    }

    /// The accessibility element for a window, to raise or restore it.
    static func element(for window: DockWindow) -> AXUIElement? {
        axWindows(of: window.processIdentifier).first { WindowSpacePrivateApis.windowID(for: $0) == window.id }
    }

    static func hasControls(_ window: DockWindow) -> Bool {
        if case .otherDesktop = window.place { return false }
        return true
    }

    private static func isBigEnough(_ bounds: CGRect) -> Bool {
        bounds.width >= minimumSize.width && bounds.height >= minimumSize.height
    }

    private static func axWindows(of pid: pid_t) -> [AXUIElement] {
        copy(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = copy(window, kAXPositionAttribute), let size = copy(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
