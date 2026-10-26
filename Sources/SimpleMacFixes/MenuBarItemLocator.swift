import AppKit
import ApplicationServices

/// Finds where the Sound, Display and Control Center icons sit in the menu bar, so the
/// macOS 27.2 volume and brightness overlay can hang beneath them like the system's own.
/// These are Accessibility queries to another process, so they run off the main thread
/// and the overlay uses the last answer.
final class MenuBarItemLocator: @unchecked Sendable {
    enum Item: String, CaseIterable {
        case sound = "com.apple.menuextra.sound"
        case display = "com.apple.menuextra.display"
        case controlCenter = "com.apple.menuextra.controlcenter"
    }

    private static let owners = ["com.apple.MenuBarAgent", "com.apple.controlcenter"]
    private let queue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.menu-bar-items", qos: .userInitiated)
    private let lock = NSLock()
    /// Distance from the right edge of the item's screen to the item's centre. Menu bar
    /// icons keep the same distance from the right edge on every screen.
    private var offsets: [Item: CGFloat] = [:]
    private var lastRefresh: TimeInterval = -.infinity
    private var isRefreshing = false

    /// When an icon isn't in the menu bar, macOS shows it in place of the Control Center
    /// icon while the overlay is up, so the overlay sits under Control Center instead.
    func offsetFromRightEdge(for item: Item) -> CGFloat? {
        lock.withLock { offsets[item] ?? offsets[.controlCenter] }
    }

    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldRun = lock.withLock { () -> Bool in
            guard !isRefreshing, now - lastRefresh > 1 else { return false }
            isRefreshing = true
            lastRefresh = now
            return true
        }
        guard shouldRun else { return }
        queue.async { [self] in
            let found = Self.lookUp()
            lock.withLock {
                offsets = found
                isRefreshing = false
            }
        }
    }

    private static func lookUp() -> [Item: CGFloat] {
        guard AXIsProcessTrusted() else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [:] }
        // Display bounds and Accessibility frames share the same top-left global space.
        let screens = ids.prefix(Int(count)).map(CGDisplayBounds)

        var result: [Item: CGFloat] = [:]
        for bundleID in owners {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.3)
                guard let bar = element.child("AXExtrasMenuBar") else { continue }
                collect(in: bar, depth: 0, screens: screens, into: &result)
            }
        }
        return result
    }

    private static func collect(in element: AXUIElement, depth: Int, screens: [CGRect], into result: inout [Item: CGFloat]) {
        if let identifier = element.string(kAXIdentifierAttribute),
           let item = Item(rawValue: identifier),
           let frame = element.frame,
           let screen = screens.first(where: { $0.minX <= frame.midX && frame.midX < $0.maxX }) {
            result[item] = screen.maxX - frame.midX
            return
        }
        guard depth < 3 else { return }
        for child in element.children {
            collect(in: child, depth: depth + 1, screens: screens, into: &result)
        }
    }
}

private extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func child(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    var children: [AXUIElement] {
        (value(kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    var frame: CGRect? {
        guard let position = value(kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
