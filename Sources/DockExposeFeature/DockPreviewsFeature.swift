import AppKit
import ApplicationServices

/// Point at a running app with more than one window to see them all, including
/// minimized ones, windows on other desktops, windows of a hidden app and
/// small windows such as Settings. Click one to go straight to it.
///
/// A simple take on DockDoor. Pointer events are only listened to, never held,
/// and every Dock and window lookup runs off the main thread, which also serves
/// the app's active event taps.
@MainActor
public final class DockPreviewsFeature {
    /// Pause on an icon before the preview opens.
    private static let openDelay: TimeInterval = 0.2
    /// Grace for moving from the icon up to the preview.
    private static let closeDelay: TimeInterval = 0.3
    private static let focusAfterSwitchTimeout: TimeInterval = 1

    /// Moves instantly to a desktop. Without it a window on another desktop is
    /// still brought forward, but macOS slides there.
    public var switchToSpace: ((UInt64) -> Bool)?

    private lazy var panel: DockPreviewPanel = {
        let panel = DockPreviewPanel()
        panel.model.choose = { [weak self] window in self?.choose(window) }
        panel.model.control = { [weak self] control, window in self?.control(control, on: window) }
        return panel
    }()
    private lazy var nameBubble = DockNameBubble()
    private var shownIcon: CGRect?
    private var shownName = ""
    /// Where the Dock drew its own bubble for the shown icon, once read, and a picture of it.
    private var measuredBubble: CGRect?
    private var bubbleSnapshot: (image: CGImage, rect: CGRect)?
    private var measureTask: Task<Void, Never>?
    private let thumbnails = WindowThumbnails()
    private let lookupQueue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.dockPreviews", qos: .userInteractive)

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var spaceObserver: NSObjectProtocol?

    private var shownBundle: String?
    private var latestPoint: CGPoint?
    private var lookupInFlight = false
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var pictureTask: Task<Void, Never>?
    private var focusAfterSwitch: DockWindow?

    public init() {}

    public var isRunning: Bool { port != nil }

    @discardableResult
    public func start() -> Bool {
        guard port == nil else { return true }
        DockAutoHideHold.recover()
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let feature = Unmanaged<DockPreviewsFeature>.fromOpaque(userInfo).takeUnretainedValue()
                let location = event.location
                MainActor.assumeIsolated { feature.handle(type, at: location) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.focusAfterSwitch else { return }
                self.focusAfterSwitch = nil
                // Let the arrival settle, then bring the window forward on its desktop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.raise(window) }
            }
        }
        return true
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        port = nil
        source = nil
        spaceObserver = nil
        hide()
    }

    private func control(_ control: DockWindows.Control, on window: DockWindow) {
        lookupQueue.async { [weak self] in
            DockWindows.perform(control, on: window)
            // Show the result: refresh the list once the app has acted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated { self?.refreshShown() }
            }
        }
    }

    private func refreshShown() {
        guard let bundleIdentifier = shownBundle, let icon = shownIcon else { return }
        lookupQueue.async { [weak self] in
            let windows = DockWindows.windows(bundleIdentifier: bundleIdentifier)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.shownBundle == bundleIdentifier else { return }
                    if windows.count > 1 {
                        self.present((bundleIdentifier, icon), windows)
                    } else {
                        self.hide()
                    }
                }
            }
        }
    }

    private func handle(_ type: CGEventType, at point: CGPoint) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .mouseMoved:
            pointerMoved(to: point)
        default:
            // Any click outside the preview closes it, including a click on the Dock itself.
            if panel.isVisible, !panelFrame.contains(point) { hide() }
        }
    }

    // MARK: Hovering

    private func pointerMoved(to point: CGPoint) {
        updateNameBubble(for: point)
        if panel.isVisible, panelFrame.insetBy(dx: -4, dy: -4).contains(point)
            || topLeft(nameBubble.frame).insetBy(dx: -4, dy: -4).contains(point) {
            cancelClose()
            return
        }
        guard DockHitTest.isInDockStrip(point) else {
            latestPoint = nil
            cancelOpen()
            scheduleClose()
            return
        }
        latestPoint = point
        lookUp()
    }

    /// One lookup at a time; the newest pointer position goes next.
    private func lookUp() {
        guard !lookupInFlight, let point = latestPoint else { return }
        lookupInFlight = true
        lookupQueue.async { [weak self] in
            let icon = DockHitTest.appIcon(at: point)
            let windows = icon.map { DockWindows.windows(bundleIdentifier: $0.bundleIdentifier) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lookupInFlight = false
                    self.found(icon, windows, at: point)
                    if let latest = self.latestPoint, hypot(latest.x - point.x, latest.y - point.y) > 2 { self.lookUp() }
                }
            }
        }
    }

    private func found(_ icon: (bundleIdentifier: String, frame: CGRect)?, _ windows: [DockWindow], at point: CGPoint) {
        guard latestPoint != nil else { return }
        // One window needs no choosing; the Dock click already brings it forward.
        guard let icon, windows.count > 1 else {
            cancelOpen()
            scheduleClose()
            return
        }
        cancelClose()
        if panel.isVisible {
            // Moving along the Dock swaps the preview straight away.
            if shownBundle != icon.bundleIdentifier || panel.model.windows != windows { present(icon, windows) }
            return
        }
        guard openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openWork = nil
            // Only if the pointer is still resting on the Dock.
            guard self.latestPoint != nil else { return }
            self.present(icon, windows)
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDelay, execute: work)
    }

    private func present(_ icon: (bundleIdentifier: String, frame: CGRect), _ windows: [DockWindow]) {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: icon.bundleIdentifier).first
        let model = panel.model
        if shownBundle != icon.bundleIdentifier {
            model.pictures = [:]
        }
        shownBundle = icon.bundleIdentifier
        shownIcon = icon.frame
        model.appName = app?.localizedName ?? ""
        model.appIcon = app?.icon
        model.windows = windows
        for window in windows where model.pictures[window.id] == nil {
            if let cached = thumbnails.cached(window.id) { model.pictures[window.id] = cached }
        }
        let edge = DockHitTest.dockEdge
        panel.show(beside: icon.frame, edge: edge, name: app?.localizedName ?? "")
        shownName = app?.localizedName ?? ""
        if nameBubble.isVisible { nameBubble.orderOut(nil) }
        measureNativeBubble(name: shownName, icon: icon.frame, edge: edge)
        if let point = latestPoint { updateNameBubble(for: point) }
        DockAutoHideHold.hold()
        pictureTask?.cancel()
        pictureTask = Task { [weak self, thumbnails] in
            for window in windows {
                guard !Task.isCancelled else { return }
                if let picture = await thumbnails.picture(of: window) {
                    guard !Task.isCancelled, self?.shownBundle == icon.bundleIdentifier else { return }
                    model.pictures[window.id] = picture
                }
            }
        }
    }

    /// The Dock shows its own name while the pointer is on the icon and drops it the
    /// moment the pointer leaves; ours takes over only then, in the same spot.
    private func updateNameBubble(for point: CGPoint) {
        guard panel.isVisible, let icon = shownIcon else { return }
        let onIcon = icon.insetBy(dx: -1, dy: -1).contains(point)
        if onIcon, nameBubble.isVisible {
            nameBubble.orderOut(nil)
        } else if !onIcon, !nameBubble.isVisible {
            showNameBubble()
        }
    }

    private func showNameBubble() {
        guard shownIcon != nil else { return }
        // Only ever the Dock's own pixels; without a picture there is no name to show.
        guard let bubbleSnapshot, let body = measuredBubble else { return }
        nameBubble.show(snapshot: bubbleSnapshot.image, at: bubbleSnapshot.rect, body: body, edge: DockHitTest.dockEdge)
    }

    /// Reads the Dock's bubble while it is still up, so ours lands exactly on it.
    /// The Dock grows its bubble in, and a reading of the wrong width is either that
    /// or the previous icon's bubble on its way out, so only two matching readings count.
    private func measureNativeBubble(name: String, icon: CGRect, edge: String) {
        measureTask?.cancel()
        measuredBubble = nil
        bubbleSnapshot = nil
        let expected = DockNameBubble.width(for: name)
        measureTask = Task { [weak self] in
            var previous: CGRect?
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                let reading = await NativeBubbleLocator.locate(near: icon, edge: edge)
                Logger.debug("Name bubble reading \(reading.map { NSStringFromRect($0) } ?? "none"), expected width \(expected)")
                guard let rect = reading, abs(rect.width - expected) <= 1 else { previous = nil; continue }
                defer { previous = rect }
                guard let previous, previous == rect, let self, self.shownIcon == icon else { continue }
                self.measuredBubble = rect
                // The bubble's size has settled. Keep retaking its picture while the pointer
                // stays on the icon, so the copy shown once it leaves is the latest and
                // matches the Dock's bubble as it finished drawing, highlights included.
                let area = Self.bubbleArea(around: rect, edge: edge)
                while !Task.isCancelled, self.shownIcon == icon, !self.nameBubble.isVisible {
                    if let snapshot = await NativeBubbleLocator.snapshot(of: area), !Task.isCancelled,
                       self.shownIcon == icon, !self.nameBubble.isVisible {
                        self.bubbleSnapshot = snapshot
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if self.nameBubble.isVisible {
                    self.nameBubble.orderOut(nil)
                    self.showNameBubble()
                }
                return
            }
        }
    }

    /// The bubble body plus its tip and a little room for the soft edge, short of the Dock bar.
    static func bubbleArea(around body: CGRect, edge: String) -> CGRect {
        let tip = DockNameBubble.tipLength + 0.5
        switch edge {
        case "left": return CGRect(x: body.minX - tip, y: body.minY - 2, width: body.width + tip + 2, height: body.height + 4)
        case "right": return CGRect(x: body.minX - 2, y: body.minY - 2, width: body.width + tip + 2, height: body.height + 4)
        default: return CGRect(x: body.minX - 2, y: body.minY - 2, width: body.width + 4, height: body.height + tip + 2)
        }
    }

    private func scheduleClose() {
        guard panel.isVisible, closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.closeWork = nil
            self?.hide()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func hide() {
        cancelOpen()
        cancelClose()
        pictureTask?.cancel()
        pictureTask = nil
        shownBundle = nil
        shownIcon = nil
        measureTask?.cancel()
        measuredBubble = nil
        bubbleSnapshot = nil
        if panel.isVisible { panel.orderOut(nil) }
        if nameBubble.isVisible { nameBubble.orderOut(nil) }
        DockAutoHideHold.release()
    }

    /// The panel's frame in the top-left coordinates of mouse events.
    private var panelFrame: CGRect { topLeft(panel.frame) }

    private func topLeft(_ frame: CGRect) -> CGRect {
        guard frame.width > 0 else { return .null }
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: Going to a window

    private func choose(_ window: DockWindow) {
        hide()
        if case let .otherDesktop(_, spaceID) = window.place, switchToSpace?(spaceID) == true {
            focusAfterSwitch = window
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusAfterSwitchTimeout) { [weak self] in
                guard let self, self.focusAfterSwitch == window else { return }
                self.focusAfterSwitch = nil
                self.raise(window)
            }
            return
        }
        raise(window)
    }

    /// Shows the app if hidden, restores the window if minimized, and brings it to the front.
    private func raise(_ window: DockWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.processIdentifier) else { return }
        if app.isHidden { app.unhide() }
        lookupQueue.async {
            if let element = DockWindows.element(for: window) {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
            DispatchQueue.main.async { _ = app.activate() }
        }
    }
}
