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

    /// The last answer read, without reading the window list again.
    nonisolated static var lastKnownIsShowing: Bool { lastCheckLock.withLock { lastCheck?.isShowing ?? false } }

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
    /// Ends with the Dock's process. macOS does not announce a Dock that restarts (Instant
    /// Dock restarts it), so without this the notices of the old Dock were watched for ever.
    private var dockExit: DispatchSourceProcess?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeDock()
    }

    func stop() {
        isRunning = false
        detach()
        isOpen = false
    }

    /// Watches the running Dock, or looks again shortly while a restarted one is not up yet.
    private func observeDock(attempt: Int = 0) {
        detach()
        isOpen = false
        guard isRunning else { return }
        guard let dock = DockHitTest.dockProcessIdentifier() else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.observeDock(attempt: attempt + 1) }
            }
            return
        }
        // A restarted Dock is a new process with nothing open.
        let exit = DispatchSource.makeProcessSource(identifier: dock, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                DockHitTest.invalidateDockProcessCache()
                self?.observeDock()
            }
        }
        exit.resume()
        dockExit = exit
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<MissionControlWatch>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { watch.received(name) }
        }
        guard AXObserverCreate(dock, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(dock)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.openNotifications.union([Self.closeNotification]) {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    private func detach() {
        dockExit?.cancel()
        dockExit = nil
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    private var confirming = false

    /// macOS 27 draws Mission Control and App Exposé in WindowManager, and the Dock's notices
    /// are not to be trusted there: one that said "opened" with no "closed" after it stopped
    /// every preview until the app restarted. So an "open" that WindowManager does not show
    /// is cleared.
    func confirmStillOpen() {
        guard isOpen, !confirming, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
        confirming = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let showing = Self.windowManagerIsShowing()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.confirming = false
                    if !showing { self.isOpen = false }
                }
            }
        }
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
