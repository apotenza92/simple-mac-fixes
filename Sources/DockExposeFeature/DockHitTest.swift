import Cocoa

struct DockHitTestStableMetadataCache {
    private var cachedDisplayBounds: [CGRect]?
    private var cachedDockProcessIdentifier: pid_t?
    private var didResolveDockProcessIdentifier = false
    private var bundleIdentifiersByURL: [URL: String] = [:]

    mutating func displayBounds(containing point: CGPoint,
                                load: () -> [CGRect]) -> CGRect? {
        if cachedDisplayBounds == nil {
            cachedDisplayBounds = load()
        }
        return cachedDisplayBounds?.first { $0.contains(point) }
    }

    mutating func dockProcessIdentifier(load: () -> pid_t?) -> pid_t? {
        if !didResolveDockProcessIdentifier {
            cachedDockProcessIdentifier = load()
            didResolveDockProcessIdentifier = true
        }
        return cachedDockProcessIdentifier
    }

    mutating func bundleIdentifier(for url: URL,
                                   load: () -> String?) -> String? {
        if let cached = bundleIdentifiersByURL[url] {
            return cached
        }
        guard let resolved = load() else { return nil }
        bundleIdentifiersByURL[url] = resolved
        return resolved
    }

    mutating func invalidateDisplayBounds() {
        cachedDisplayBounds = nil
    }

    mutating func invalidateDockProcessIdentifier() {
        cachedDockProcessIdentifier = nil
        didResolveDockProcessIdentifier = false
        bundleIdentifiersByURL.removeAll()
    }
}

private func dockHitTestDisplayReconfigurationCallback(_ display: CGDirectDisplayID,
                                                       _ flags: CGDisplayChangeSummaryFlags,
                                                       _ userInfo: UnsafeMutableRawPointer?) {
    DockHitTest.invalidateDisplayBoundsCache()
}

enum DockHitTest {
    enum PointKind: Equatable {
        case appDockIcon(String)
        case folderDockItem(URL)
        case dockBackground
        case outsideDock
    }

    private final class StableMetadataObserver {
        private var workspaceObservers: [NSObjectProtocol] = []

        init() {
            CGDisplayRegisterReconfigurationCallback(dockHitTestDisplayReconfigurationCallback, nil)
            let center = NSWorkspace.shared.notificationCenter
            let invalidateDock: (Notification) -> Void = { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.dock" else { return }
                DockHitTest.invalidateDockProcessCache()
            }
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                         object: nil,
                                                         queue: .main,
                                                         using: invalidateDock))
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                         object: nil,
                                                         queue: .main,
                                                         using: invalidateDock))
        }

        deinit {
            CGDisplayRemoveReconfigurationCallback(dockHitTestDisplayReconfigurationCallback, nil)
            for observer in workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }
    }

    private static let stableMetadataLock = NSLock()
    private static var stableMetadataCache = DockHitTestStableMetadataCache()
    private static let stableMetadataObserver = StableMetadataObserver()

    static func bundleIdentifierAtPoint(_ point: CGPoint) -> String? {
        if case let .appDockIcon(bundle) = pointKind(at: point) {
            return bundle
        }
        return nil
    }

    static func folderURLAtPoint(_ point: CGPoint) -> URL? {
        if case let .folderDockItem(url) = pointKind(at: point) {
            return url
        }
        return nil
    }

    static func classifyDockItem(subrole: String?, url: URL?) -> PointKind? {
        switch subrole {
        case "AXFolderDockItem":
            guard let url, url.isFileURL else { return nil }
            return .folderDockItem(url.standardizedFileURL)
        case "AXApplicationDockItem":
            guard let bundleIdentifier = bundleIdentifier(forApplicationURL: url) else { return nil }
            return .appDockIcon(bundleIdentifier)
        default:
            break
        }

        // Some Dock folder stacks intermittently resolve without the expected folder subrole.
        // If AX still gives us a file URL that is not an app bundle, treat it as a folder item.
        if let url, url.isFileURL, bundleIdentifier(forApplicationURL: url) == nil {
            Logger.debug("Hit test falling back to folder classification for URL: \(url.path) subrole=\(subrole ?? "nil")")
            return .folderDockItem(url.standardizedFileURL)
        }

        return nil
    }

    /// The running app's Dock icon under `point`, with the icon's frame in
    /// top-left screen coordinates, so a preview can sit next to it.
    static func appIcon(at point: CGPoint) -> (bundleIdentifier: String, frame: CGRect)? {
        _ = stableMetadataObserver
        guard isNearDockEdge(point), let element = element(at: point), isInDockProcess(element) else { return nil }
        var current: AXUIElement? = element
        while let item = current, isInDockProcess(item) {
            if case let .appDockIcon(bundleIdentifier)? = dockItemKind(for: item) {
                return frame(of: item).map { (bundleIdentifier, $0) }
            }
            current = parent(of: item)
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func pointKind(at point: CGPoint) -> PointKind {
        _ = stableMetadataObserver
        guard isNearDockEdge(point) else { return .outsideDock }
        guard let element = element(at: point) else { return .outsideDock }
        guard isInDockProcess(element) else { return .outsideDock }

        if let pointKind = dockItemKind(for: element) {
            return pointKind
        }

        var current: AXUIElement? = parent(of: element)
        while let el = current, isInDockProcess(el) {
            if let pointKind = dockItemKind(for: el) {
                return pointKind
            }
            current = parent(of: el)
        }

        Logger.debug("Hit test resolved Dock background.")
        return .dockBackground
    }

    static func neutralBackgroundPoint(near point: CGPoint,
                                       searchRadius: CGFloat = 120,
                                       step: CGFloat = 12) -> CGPoint? {
        // Recovery runs on the event-tap run loop; never scan hundreds of AX points
        // while a physical release is waiting to be delivered.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.01
        if pointKind(at: point) == .dockBackground {
            return point
        }

        let offsets = stride(from: CGFloat(0), through: searchRadius, by: step).flatMap { distance -> [CGFloat] in
            distance == 0 ? [0] : [distance, -distance]
        }

        // Prefer short cardinal moves first; they are less likely to wander onto a neighboring
        // Dock item than a diagonal grid search when the pressed icon is large.
        for distance in stride(from: step, through: searchRadius, by: step) {
            let candidates = [
                CGPoint(x: point.x, y: point.y - distance),
                CGPoint(x: point.x, y: point.y + distance),
                CGPoint(x: point.x - distance, y: point.y),
                CGPoint(x: point.x + distance, y: point.y)
            ]
            for candidate in candidates {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                if pointKind(at: candidate) == .dockBackground { return candidate }
            }
        }

        for dy in offsets {
            for dx in offsets {
                if dx == 0, dy == 0 { continue }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                let candidate = CGPoint(x: point.x + dx, y: point.y + dy)
                if pointKind(at: candidate) == .dockBackground {
                    return candidate
                }
            }
        }

        // Final coarse fallback for large Dock magnification / spacing cases.
        for distance in stride(from: searchRadius + step, through: searchRadius + 72, by: 24) {
            let candidates = [
                CGPoint(x: point.x, y: point.y - distance),
                CGPoint(x: point.x - distance, y: point.y),
                CGPoint(x: point.x + distance, y: point.y)
            ]
            for candidate in candidates {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                if pointKind(at: candidate) == .dockBackground { return candidate }
            }
        }

        return nil
    }

    nonisolated(unsafe) private static var dockGeometry: (edge: String, thickness: CGFloat, expiresAt: TimeInterval)?

    /// The screen edge the Dock sits on: "bottom", "left" or "right".
    static var dockEdge: String {
        _ = isInDockStrip(.zero)
        stableMetadataLock.lock()
        defer { stableMetadataLock.unlock() }
        return dockGeometry?.edge ?? "bottom"
    }

    /// Whether `point` is in the thin strip the Dock bar occupies, from the Dock's
    /// own settings. Costs no accessibility query, so it can gate one on the click path.
    static func isInDockStrip(_ point: CGPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        stableMetadataLock.lock()
        var geometry = dockGeometry
        stableMetadataLock.unlock()
        if geometry == nil || geometry!.expiresAt < now {
            let domain = "com.apple.dock" as CFString
            CFPreferencesAppSynchronize(domain)
            let edge = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "bottom"
            let tile = CFPreferencesCopyAppValue("tilesize" as CFString, domain) as? Double ?? 64
            var magnified = false
            if let value = CFPreferencesCopyAppValue("magnification" as CFString, domain) as? NSNumber { magnified = value.boolValue }
            let large = magnified ? (CFPreferencesCopyAppValue("largesize" as CFString, domain) as? Double ?? tile) : tile
            geometry = (edge, CGFloat(max(tile, large)) + 24, now + 5)
            stableMetadataLock.lock()
            dockGeometry = geometry
            stableMetadataLock.unlock()
        }
        guard let geometry, let bounds = displayBounds(containing: point) else { return false }
        switch geometry.edge {
        case "left": return point.x - bounds.minX <= geometry.thickness
        case "right": return bounds.maxX - point.x <= geometry.thickness
        default: return bounds.maxY - point.y <= geometry.thickness
        }
    }

    private static func isNearDockEdge(_ point: CGPoint, threshold: CGFloat = 140) -> Bool {
        // IMPORTANT: `point` is in Quartz global display coordinates (CGEvent.location),
        // where Y is measured from the top of the display (y grows downward).
        // Do not use NSScreen frames here (AppKit uses a flipped Y for screen coordinates).
        guard let bounds = displayBounds(containing: point) else {
            return false
        }

        let distLeft = point.x - bounds.minX
        let distRight = bounds.maxX - point.x
        let distBottom = bounds.maxY - point.y

        // Dock can be positioned on the left, right, or bottom edge.
        return distLeft <= threshold || distRight <= threshold || distBottom <= threshold
    }

    static func invalidateDisplayBoundsCache() {
        stableMetadataLock.lock()
        stableMetadataCache.invalidateDisplayBounds()
        stableMetadataLock.unlock()
    }

    static func invalidateDockProcessCache() {
        stableMetadataLock.lock()
        stableMetadataCache.invalidateDockProcessIdentifier()
        stableMetadataLock.unlock()
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        stableMetadataLock.lock()
        defer { stableMetadataLock.unlock() }
        return stableMetadataCache.displayBounds(containing: point) {
            activeDisplayBounds()
        }
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) != .success || count == 0 {
            return []
        }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        if CGGetActiveDisplayList(count, &displays, &count) != .success {
            return []
        }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        guard result == .success else {
            Logger.debug("AXUIElementCopyElementAtPosition failed with \(result.rawValue)")
            return nil
        }
        return element
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success else { return nil }
        guard let cfValue = value, CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return (cfValue as! AXUIElement)
    }

    private static func isInDockProcess(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success else {
            Logger.debug("AXUIElementGetPid failed with \(result.rawValue)")
            return false
        }
        stableMetadataLock.lock()
        let dockPID = stableMetadataCache.dockProcessIdentifier {
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == "com.apple.dock"
            }?.processIdentifier
        }
        stableMetadataLock.unlock()
        if pid == dockPID { return true }
        // The Dock relaunches with a new pid whenever it restarts (Instant Dock
        // does this), and macOS doesn't announce that for background processes.
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" else {
            Logger.debug("Element pid \(pid) is not cached Dock pid \(dockPID.map(String.init) ?? "nil").")
            return false
        }
        invalidateDockProcessCache()
        return true
    }

    private static func dockItemKind(for element: AXUIElement) -> PointKind? {
        let subrole: String? = attribute(element, for: kAXSubroleAttribute)
        let url: URL? = attribute(element, for: kAXURLAttribute)

        if let pointKind = classifyDockItem(subrole: subrole, url: url) {
            switch pointKind {
            case .folderDockItem(let url):
                Logger.debug("Hit test resolved folder URL: \(url.path)")
            case .appDockIcon(let bundle):
                Logger.debug("Hit test resolved bundle: \(bundle)")
            case .dockBackground, .outsideDock:
                break
            }
            return pointKind
        }

        if subrole == "AXApplicationDockItem" {
            let title: String = attribute(element, for: kAXTitleAttribute) ?? ""
            Logger.debug("Hit test unresolved app Dock item title=\(title) url=\(url?.path ?? "nil")")
        }

        return nil
    }

    private static func bundleIdentifier(forApplicationURL url: URL?) -> String? {
        guard let url else { return nil }
        stableMetadataLock.lock()
        let bundleIdentifier = stableMetadataCache.bundleIdentifier(for: url) {
            Bundle(url: url)?.bundleIdentifier
        }
        stableMetadataLock.unlock()
        guard let bundleIdentifier else {
            Logger.debug("No bundleIdentifier resolved from AXURL: \(url.path)")
            return nil
        }
        Logger.debug("Bundle from AXURL: \(bundleIdentifier)")
        return bundleIdentifier == "com.apple.dock" ? nil : bundleIdentifier
    }

    private static func attribute<T>(_ element: AXUIElement, for key: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }
}
