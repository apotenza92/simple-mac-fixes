import AppKit
import ApplicationServices

/// One of an app's windows, wherever it is: this desktop, another desktop,
/// minimized, or belonging to a hidden app.
public struct DockWindow: Identifiable, Equatable {
    public enum Place: Equatable {
        case here
        case otherDesktop
        case minimized
        case hidden
    }

    public let id: CGWindowID
    public let processIdentifier: pid_t
    public let title: String
    public let place: Place
    let bounds: CGRect

    /// On a screen now, on this desktop or another one: not minimized, and not in a hidden app.
    var isOnScreen: Bool { place == .here || place == .otherDesktop }

    func moved(to place: Place) -> DockWindow {
        DockWindow(id: id, processIdentifier: processIdentifier, title: title, place: place, bounds: bounds)
    }
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

    /// A window's name for its card. Some apps, such as some browsers, give every window
    /// only the app's name over accessibility, while the window server has the real one.
    static func title(accessibility: String?, server: String?, appName: String?) -> String {
        let names = [accessibility, server].compactMap { $0 }.filter { !$0.isEmpty }
        return names.first { $0 != appName } ?? names.first ?? ""
    }

    static func windows(bundleIdentifier: String) -> [DockWindow] {
        windows(bundleIdentifiers: [bundleIdentifier])[bundleIdentifier] ?? []
    }

    /// Several apps' windows at once. The window server's lists, which take the most
    /// time, are read once for all of them.
    static func windows(bundleIdentifiers: [String]) -> [String: [DockWindow]] {
        let appsByBundle = Dictionary(grouping: bundleIdentifiers.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }, by: { $0.bundleIdentifier ?? "" })
        guard !appsByBundle.isEmpty else { return [:] }
        let allPIDs = Set(appsByBundle.values.joined().map(\.processIdentifier))
        func pid(_ entry: [String: Any]) -> pid_t { (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0 }

        // Every desktop's windows, with sizes and window-server titles. This list isn't
        // in front-to-back order; the on-screen list below is.
        let allEntries = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).filter { allPIDs.contains(pid($0)) && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let allOnScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).filter { allPIDs.contains(pid($0)) }
        let visibleSpaces = Set(WindowSpacePrivateApis.activeSpaceIDs().map { Int($0) })

        var results: [String: [DockWindow]] = [:]
        for (bundleIdentifier, apps) in appsByBundle {
            let pids = Set(apps.map(\.processIdentifier))
            let hidden = apps.contains(where: \.isHidden)
            let entries = allEntries.filter { pids.contains(pid($0)) }
            var order: [CGWindowID: Int] = [:]
            let onScreen = allOnScreen.filter { pids.contains(pid($0)) }
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
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
                    let title = Self.title(accessibility: string(window, kAXTitleAttribute), server: info[id]?.title,
                                           appName: app.localizedName)
                    result.append(DockWindow(id: id, processIdentifier: app.processIdentifier, title: title,
                                             place: minimized ? .minimized : hidden ? .hidden : .here, bounds: bounds))
                }
            }

            // Windows on other desktops never appear in the accessibility list.
            for entry in entries {
                guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !seen.contains(id),
                      let window = info[id], window.alpha > 0.01, isBigEnough(window.bounds) else { continue }
                let spaces = WindowSpacePrivateApis.spaces(for: id)
                // No space means a helper window that is never shown.
                guard !spaces.isEmpty, spaces.isDisjoint(with: visibleSpaces) else { continue }
                seen.insert(id)
                result.append(DockWindow(id: id, processIdentifier: pid(entry), title: window.title,
                                         place: hidden ? .hidden : .otherDesktop, bounds: window.bounds))
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
            results[bundleIdentifier] = result.sorted {
                (group($0), order[$0.id] ?? .max) < (group($1), order[$1.id] ?? .max)
            }
        }
        return results
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
