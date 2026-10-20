import AppKit
import ApplicationServices

/// Whether Mission Control or App Exposé is open. Pointing at the Dock's icons
/// while one is open belongs to it, not to the previews.
///
/// Older macOS draws both in the Dock, which announces them over accessibility.
/// Newer macOS draws them in WindowManager and announces nothing, but puts up a
/// screen-sized window just below the Dock's level while either is open.
@MainActor
final class MissionControlWatch {
    /// The level WindowManager draws Mission Control and App Exposé at, one below the Dock.
    nonisolated static let windowManagerLevel = 19

    nonisolated private static let lastCheckLock = NSLock()
    nonisolated(unsafe) private static var lastCheck: (isShowing: Bool, at: TimeInterval)?
    /// Reading the window list takes a couple of milliseconds; lookups come faster than that matters.
    nonisolated private static let checkMaxAge: TimeInterval = 0.15

    /// Whether WindowManager is showing Mission Control or App Exposé. Reads the window
    /// list, so it runs off the main thread.
    nonisolated static func windowManagerIsShowing() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastCheckLock.withLock({ lastCheck }), now - last.at < checkMaxAge { return last.isShowing }
        let isShowing = readWindowList()
        lastCheckLock.withLock { lastCheck = (isShowing, now) }
        return isShowing
    }

    nonisolated private static func readWindowList() -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains { entry in
            guard entry[kCGWindowOwnerName as String] as? String == "WindowManager",
                  entry[kCGWindowLayer as String] as? Int == windowManagerLevel,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return false }
            // Screen-sized, unlike anything smaller WindowManager might put there.
            return bounds.width >= 400 && bounds.height >= 300
        }
    }

    /// Opening Mission Control (all windows) and App Exposé (one app's windows).
    nonisolated static let openNotifications: Set<String> = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"]
    /// Showing the desktop also announces its end this way, so it closes nothing that isn't open.
    nonisolated static let closeNotification = "AXExposeExit"

    private(set) var isOpen = false
    /// Called when Mission Control or App Exposé opens.
    var opened: (() -> Void)?

    private var observer: AXObserver?
    private var dockObservers: [NSObjectProtocol] = []

    func start() {
        guard dockObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        // A restarted Dock is a new process with nothing open.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            dockObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.dock" else { return }
                MainActor.assumeIsolated { self?.observeDock() }
            })
        }
        observeDock()
    }

    func stop() {
        dockObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        dockObservers = []
        detach()
        isOpen = false
    }

    private func observeDock() {
        detach()
        isOpen = false
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<MissionControlWatch>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { watch.received(name) }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.openNotifications.union([Self.closeNotification]) {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    private func detach() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    private func received(_ name: String) {
        if Self.openNotifications.contains(name) {
            Logger.debug("Mission Control or App Exposé opened (\(name))")
            isOpen = true
            opened?()
        } else if name == Self.closeNotification {
            Logger.debug("Mission Control or App Exposé closed")
            isOpen = false
        }
    }
}
