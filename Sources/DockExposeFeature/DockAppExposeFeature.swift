import AppKit

/// Clicking a running app's Dock icon shows App Exposé for that app.
///
/// Ported from Dockmint's default first-click behaviour, with every other Dock
/// action removed. The tap only listens: the Dock always receives the complete
/// native click, and App Exposé follows when the app has more than one
/// window. With one window the click just brings it forward, as usual.
@MainActor
public final class DockAppExposeFeature {
    private struct PendingClick {
        let bundleIdentifier: String
        let location: CGPoint
        let frontmostBefore: String?
    }

    private static let dragThreshold: CGFloat = 6
    /// A second click on the same icon this soon after App Exposé opened dismisses it.
    private static let trackingExpiry: TimeInterval = 0.9
    private static let dockBundleIdentifier = "com.apple.dock"

    private let invoker = AppExposeInvoker()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var pending: PendingClick?
    private var clickToken: UInt64 = 0
    private var invocationToken: UUID?
    private var exposeBundleIdentifier: String?
    private var lastExposeInteraction: TimeInterval = 0

    public init() {}

    public var isRunning: Bool { port != nil }

    @discardableResult
    public func start() -> Bool {
        guard port == nil else { return true }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let feature = Unmanaged<DockAppExposeFeature>.fromOpaque(userInfo).takeUnretainedValue()
                MainActor.assumeIsolated { feature.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.applicationActivated(app?.bundleIdentifier) }
        }
        return true
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        port = nil
        source = nil
        activationObserver = nil
        pending = nil
        resetTracking()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            pending = nil
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .leftMouseDown:
            mouseDown(at: event.location, flags: event.flags)
        case .leftMouseDragged:
            if let pending, distance(pending.location, event.location) >= Self.dragThreshold {
                // Dragging reorders or removes Dock items.
                self.pending = nil
            }
        case .leftMouseUp:
            mouseUp(at: event.location)
        default:
            break
        }
    }

    private func mouseDown(at location: CGPoint, flags: CGEventFlags) {
        clickToken &+= 1
        pending = nil
        guard case let .appDockIcon(bundleIdentifier) = DockHitTest.pointKind(at: location) else {
            if exposeBundleIdentifier != nil { resetTracking() }
            return
        }
        // Modifier clicks keep their native Dock meaning, such as Option to hide.
        guard flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty,
              isRunning(bundleIdentifier) else { return }
        // Count windows in the background so the click itself is never delayed.
        WindowManager.prewarmAppExposeWindowCount(bundleIdentifier: bundleIdentifier)
        pending = PendingClick(
            bundleIdentifier: bundleIdentifier,
            location: location,
            frontmostBefore: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    private func mouseUp(at location: CGPoint) {
        guard let click = pending else { return }
        pending = nil
        guard distance(click.location, location) < Self.dragThreshold else { return }
        let bundleIdentifier = click.bundleIdentifier
        let now = ProcessInfo.processInfo.systemUptime

        if let tracked = exposeBundleIdentifier, now - lastExposeInteraction <= Self.trackingExpiry {
            if tracked == bundleIdentifier {
                // The Dock dismisses App Exposé and focuses the app; never reopen it on the same click.
                resetTracking()
            } else {
                // The Dock switches App Exposé to the clicked app by itself.
                exposeBundleIdentifier = bundleIdentifier
                lastExposeInteraction = now
            }
            return
        }
        resetTracking()

        if let count = WindowManager.appExposeWindowCountDiagnosticsAfterPrewarmIfAvailable(
            bundleIdentifier: bundleIdentifier
        )?.finalCount {
            if Self.shouldShowAppExpose(windowCount: count) { showAppExpose(for: bundleIdentifier) }
            return
        }
        // The count is still being taken. The native click has already gone through;
        // follow it with App Exposé only if no newer click has happened since.
        let token = clickToken
        WindowManager.whenAppExposeWindowCountPrewarmCompletes(bundleIdentifier: bundleIdentifier) { [weak self] diagnostics in
            MainActor.assumeIsolated {
                guard let self, token == self.clickToken,
                      Self.shouldShowAppExpose(windowCount: diagnostics.finalCount) else { return }
                self.showAppExpose(for: bundleIdentifier)
            }
        }
    }

    nonisolated static func shouldShowAppExpose(windowCount: Int) -> Bool {
        windowCount > 1
    }

    private func showAppExpose(for bundleIdentifier: String) {
        let token = UUID()
        invocationToken = token
        lastExposeInteraction = ProcessInfo.processInfo.systemUptime
        WindowManager.invalidateWindowQueryCache(bundleIdentifier: bundleIdentifier)
        // App Exposé applies to the frontmost app, so wait briefly for activation.
        activate(bundleIdentifier)
        waitForActivation(of: bundleIdentifier, token: token, remainingAttempts: 4)
    }

    private func waitForActivation(of bundleIdentifier: String, token: UUID, remainingAttempts: Int) {
        guard invocationToken == token else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard frontmost == bundleIdentifier || remainingAttempts == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                self.activate(bundleIdentifier)
                self.waitForActivation(of: bundleIdentifier, token: token, remainingAttempts: remainingAttempts - 1)
            }
            return
        }
        invoker.invokeApplicationWindows(for: bundleIdentifier, requireEvidence: true) { [weak self] result in
            guard let self, self.invocationToken == token else { return }
            self.invocationToken = nil
            WindowManager.invalidateWindowQueryCache(bundleIdentifier: bundleIdentifier)
            if result.confirmed || result.acknowledged {
                self.exposeBundleIdentifier = bundleIdentifier
                self.lastExposeInteraction = ProcessInfo.processInfo.systemUptime
            } else {
                self.resetTracking()
            }
        }
    }

    private func activate(_ bundleIdentifier: String) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return }
        if app.isHidden { app.unhide() }
        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
    }

    private func applicationActivated(_ bundleIdentifier: String?) {
        guard invocationToken == nil, let tracked = exposeBundleIdentifier,
              bundleIdentifier != tracked, bundleIdentifier != Self.dockBundleIdentifier else { return }
        resetTracking()
    }

    private func resetTracking() {
        invocationToken = nil
        exposeBundleIdentifier = nil
        lastExposeInteraction = 0
    }

    private func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
