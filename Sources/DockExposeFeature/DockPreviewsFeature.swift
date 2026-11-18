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
    /// Grace for moving from the icon up to the preview.
    private static let closeDelay: TimeInterval = 0.3
    private static let focusAfterSwitchTimeout: TimeInterval = 1

    /// Moves instantly to a desktop. Without it a window on another desktop is
    /// still brought forward, but macOS slides there.
    public var switchToSpace: ((UInt64) -> Bool)?
    /// The green button as the window's own would act, given whether Option is held;
    /// false leaves it to the button's usual full screen. Called off the main thread.
    public var pressGreenButton: ((AXUIElement, Bool) -> Bool)?
    /// Instant Dock is on: the preview opens, closes and changes at once, as with Reduce Motion.
    public var instantDock = false

    /// The system's own animations, unless the person asked for less motion or an instant Dock.
    private var animates: Bool {
        !instantDock && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private lazy var panel: DockPreviewPanel = {
        let panel = DockPreviewPanel()
        panel.model.choose = { [weak self] window in self?.choose(window) }
        panel.model.control = { [weak self] control, window in self?.control(control, on: window) }
        panel.model.pointAt = { [weak self] window, isOn in self?.pointAt(window, isOn) }
        return panel
    }()
    private var shownIcon: CGRect?
    private let thumbnails = WindowThumbnails()
    /// Plays the card under the pointer, and its window when it is shown in place.
    private lazy var liveWindow: LiveWindow = {
        let live = LiveWindow(model: panel.model, thumbnails: thumbnails)
        live.frame = { [weak self] id, image in
            guard let self, self.peeking == id else { return }
            self.peek.updateLive(image)
        }
        return live
    }()
    /// No preview while Mission Control or App Exposé is open: the Dock's icons are its own then.
    private let missionControl = MissionControlWatch()
    /// Looks for Mission Control opening while the preview shows; newer macOS doesn't announce it.
    private var missionControlCheck: Timer?
    private let lookupQueue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.dockPreviews", qos: .userInteractive)
    /// Reads window lists ahead of need and checks for Mission Control, apart from the
    /// lookups that follow the pointer, so neither waits for the other.
    private let backgroundQueue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.dockPreviews.ahead", qos: .userInitiated)
    /// Only used on `lookupQueue`.
    private let recentWindows = RecentWindows()
    /// Window buttons and bringing windows forward wait on the app and on resizing, so
    /// they run apart from the lookups that follow the pointer.
    private let actionQueue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.dockPreviews.actions", qos: .userInitiated)

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// The only tap that changes events: it holds pointer moves back from the Dock while
    /// they stay on a previewed icon. See `holdsMoveBack(at:)`.
    private var movePort: CFMachPort?
    private var moveSource: CFRunLoopSource?
    private var spaceObserver: NSObjectProtocol?

    private var shownBundle: String?
    private var latestPoint: CGPoint?
    private var lookupInFlight = false
    private var lastReadAhead: TimeInterval = 0
    /// The Dock's app icons, read while the Dock showed, to find the icon under the
    /// pointer without asking the Dock. Main thread only.
    private var dockItems: [(bundleIdentifier: String, frame: CGRect)] = []
    private var dockItemsReadAt: TimeInterval = 0
    /// Whether the Dock was told the pointer left it, to take its name label down.
    private var hidingDockLabel = false
    /// Looks again at a pointer that stopped where no icon was found yet.
    private var retryWork: DispatchWorkItem?
    private var retries = 0
    /// Reads the shown icon again while magnification may still be resizing it.
    private var followWork: DispatchWorkItem?
    /// Reads in a row that found the shown icon's frame unchanged.
    private var steadyReads = 0
    private var closeWork: DispatchWorkItem?
    /// Recent pointer positions, for which way it's heading.
    private var motion: [(point: CGPoint, time: TimeInterval)] = []
    /// Re-checks an icon that was passed over on the way to the preview, in case the pointer stopped on it.
    private var aimWork: DispatchWorkItem?
    private var pictureTask: Task<Void, Never>?
    private var focusAfterSwitch: DockWindow?
    private var focusAfterSwitchDone: (() -> Void)?

    public init() {}

    public var isRunning: Bool { port != nil }

    @discardableResult
    public func start() -> Bool {
        guard port == nil else { return true }
        DockAutoHideHold.recover()
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let feature = Unmanaged<DockPreviewsFeature>.fromOpaque(userInfo).takeUnretainedValue()
                let location = event.location
                let scroll = type == .scrollWheel ? Scroll(event) : nil
                MainActor.assumeIsolated { feature.handle(type, at: location, scroll: scroll) }
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
        startHoldingMovesBack()
        missionControl.opened = { [weak self] in self?.hide() }
        // Do everything once now that is slow the first time, so the first preview opens
        // as fast as later ones: drawing the panel, asking each app for its windows,
        // asking the Dock for its icons and for what is under a point.
        panel.prepare()
        backgroundQueue.async { [recentWindows] in recentWindows.readAhead() }
        refreshDockItems()
        lookupQueue.async {
            _ = MissionControlWatch.windowManagerIsShowing()
            if let item = DockHitTest.appItems().first {
                _ = DockHitTest.appIcon(at: CGPoint(x: item.frame.midX, y: item.frame.midY))
            }
        }
        missionControl.start()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The cards' desktop labels change with the desktop; their order doesn't.
                if self.panel.isVisible { self.refreshShown() }
                guard let window = self.focusAfterSwitch else { return }
                self.focusAfterSwitch = nil
                let done = self.focusAfterSwitchDone ?? {}
                self.focusAfterSwitchDone = nil
                // Let the arrival settle, then bring the window forward on its desktop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.raise(window, then: done) }
            }
        }
        return true
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let movePort { CGEvent.tapEnable(tap: movePort, enable: false); CFMachPortInvalidate(movePort) }
        if let moveSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), moveSource, .commonModes) }
        movePort = nil
        moveSource = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        missionControl.stop()
        port = nil
        source = nil
        spaceObserver = nil
        hide()
    }

    private func control(_ control: DockWindows.Control, on window: DockWindow) {
        let optionPressed = NSEvent.modifierFlags.contains(.option)
        let pressGreenButton = pressGreenButton
        actionQueue.async { [weak self] in
            if control == .maximize, let element = DockWindows.element(for: window),
               pressGreenButton?(element, optionPressed) == true {
                // Done the way the window's own green button does it, which returns once
                // the window has settled at its new size.
            } else {
                DockWindows.perform(control, on: window)
            }
            // Show the result straight away, and again once any animation, such as
            // minimizing, has finished.
            for delay in [0, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.thumbnails.expire(window.id)
                        self.fullPictures[window.id] = nil
                        self.refreshShown()
                    }
                }
            }
        }
    }

    private func refreshShown() {
        guard let bundleIdentifier = shownBundle, let icon = shownIcon else { return }
        lookupQueue.async { [weak self, recentWindows] in
            let windows = recentWindows.windows(of: bundleIdentifier, maxAge: 0)
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

    private func handle(_ type: CGEventType, at point: CGPoint, scroll: Scroll?) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .mouseMoved:
            pointerMoved(to: point)
        case .scrollWheel:
            if let scroll { scrolled(scroll, at: point) }
        default:
            guard panel.isVisible, !panelFrame.contains(point) else { return }
            // Clicking the icon keeps the preview up. The Dock's own click brings the
            // app's front window forward; a different pick follows straight after it.
            if type == .leftMouseDown, shownIcon?.contains(point) == true {
                let pick = pickedByIconClick()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.afterDockClick) { [weak self] in
                    guard let self, self.panel.isVisible else { return }
                    if let pick { self.choose(pick, keepOpen: true) }
                    // The app coming forward takes key from the panel, which would frost
                    // its glass, and may reorder its windows.
                    self.refreshShown()
                }
                return
            }
            // Any other click outside the preview closes it, including the Dock's menu.
            hide()
        }
    }

    // MARK: Hovering

    private func pointerMoved(to point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        motion.append((point, now))
        motion.removeAll { now - $0.time > Self.headingWindow }
        if missionControl.isOpen {
            latestPoint = nil
            if panel.isVisible { hide() }
            return
        }
        if point != latestPoint {
            retries = 0
            steadyReads = 0
        }
        if DockHitTest.checkDockEdge(near: point) {
            // The icons moved with the Dock; the old list would find none, or the wrong one.
            dockItems = []
            dockItemsReadAt = 0
            if panel.isVisible { hide() }
            refreshDockItems()
        }
        if now - lastReadAhead > 0.1, DockHitTest.isInDockStrip(point, margin: Self.readAheadDistance) {
            lastReadAhead = now
            backgroundQueue.async { [recentWindows] in recentWindows.readAhead() }
        }
        let inDockStrip = DockHitTest.isInDockStrip(point)
        // The way from the icon to the preview, past the Dock's name bubble, keeps it open too.
        if panel.isVisible, panelFrame.insetBy(dx: -4, dy: -4).contains(point)
            || (!inDockStrip && bridgeFrame.contains(point)) {
            cancelClose()
            cancelAim()
            return
        }
        guard inDockStrip else {
            latestPoint = nil
            scheduleClose()
            return
        }
        latestPoint = point
        openFromMemory(at: point)
        lookUp()
        hideDockLabel()
    }

    /// The preview covers the Dock's name label, but its glass is the Dock's own, which
    /// lets the label show through. Without magnification, after each move tell the Dock
    /// the pointer has left, so it takes the label down. Only the Dock is told: the real
    /// pointer stays on the icon and its clicks still reach the Dock. With magnification
    /// that would shrink the icon under the pointer, so there the label stays.
    private func hideDockLabel() {
        guard panel.isVisible, !DockHitTest.dockMagnifies else { return }
        hidingDockLabel = true
        // After this event has reached the Dock, so the Dock's answer to it comes first.
        DispatchQueue.main.async { Self.postToDock(Self.offScreen) }
    }

    /// Pointer moves only, never clicks or scrolls, and only while `holdsMoveBack(at:)`.
    /// Without this tap the feature still works; the label then shows through.
    private func startHoldingMovesBack() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let feature = Unmanaged<DockPreviewsFeature>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let port = feature.movePort { CGEvent.tapEnable(tap: port, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }
            let location = event.location
            let holdBack = MainActor.assumeIsolated { () -> Bool in
                guard feature.holdsMoveBack(at: location) else { return false }
                // The listening tap won't see it now, so follow the pointer here.
                feature.handle(.mouseMoved, at: location, scroll: nil)
                return true
            }
            return holdBack ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue,
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        movePort = port
        moveSource = source
    }

    /// A move on the previewed icon, once the Dock was told the pointer left to take its
    /// label down, would bring the label straight back for a frame or two. Moves on the
    /// icon tell the Dock nothing it needs: without magnification the icon looks the same,
    /// and the pointer itself still moves. Every other move goes through untouched.
    private func holdsMoveBack(at point: CGPoint) -> Bool {
        hidingDockLabel && panel.isVisible && !DockHitTest.dockMagnifies && shownIcon?.contains(point) == true
    }

    /// A point on no screen.
    private static let offScreen = CGPoint(x: -500, y: -500)

    /// Opens the preview inside the mouse event, from the Dock's icons and the window
    /// lists read ahead, with no wait for the Dock. The lookup that follows asks the
    /// Dock and corrects it. Magnification moves the icons, so then only the lookup counts.
    private func openFromMemory(at point: CGPoint) {
        guard !DockHitTest.dockMagnifies, !MissionControlWatch.lastKnownIsShowing,
              let item = DockHitTest.appItem(at: point, in: dockItems),
              !(panel.isVisible && item.bundleIdentifier == shownBundle),
              let windows = recentWindows.cachedWindowsToOpen(item.bundleIdentifier) else { return }
        found(item, windows, at: point)
    }

    /// Reads the Dock's icons again, at most twice a second.
    private func refreshDockItems() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - dockItemsReadAt > 0.5 else { return }
        dockItemsReadAt = now
        backgroundQueue.async { [weak self] in
            let items = DockHitTest.appItems()
            // A hidden Dock reports its icons off screen: keep the list read while it showed.
            guard !items.isEmpty,
                  items.allSatisfy({ DockHitTest.isInDockStrip(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dockItems = items } }
        }
    }

    /// A pointer move sent to the Dock alone; the real pointer stays where it is.
    private static func postToDock(_ point: CGPoint) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .postToPid(dock.processIdentifier)
    }

    /// One lookup at a time; the newest pointer position goes next.
    private func lookUp() {
        guard !lookupInFlight, let point = latestPoint else { return }
        lookupInFlight = true
        lookupQueue.async { [weak self, recentWindows] in
            // The last answer, so the pointer's path never waits on the window list; a
            // fresh one follows and closes a preview that opened over Mission Control.
            let missionControlOpen = MissionControlWatch.lastKnownIsShowing
            self?.backgroundQueue.async {
                guard MissionControlWatch.windowManagerIsShowing(), !missionControlOpen else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.hide() } }
            }
            let icon = missionControlOpen ? nil : DockHitTest.appIcon(at: point)
            let windows = icon.map { recentWindows.windowsToOpen($0.bundleIdentifier) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lookupInFlight = false
                    if missionControlOpen {
                        self.hide()
                        return
                    }
                    self.found(icon, windows, at: point)
                    if let icon, !DockHitTest.dockMagnifies, !self.dockItems.contains(where: {
                        $0.bundleIdentifier == icon.bundleIdentifier && Self.isSame($0.frame, icon.frame)
                    }) {
                        self.refreshDockItems()
                    }
                    if let latest = self.latestPoint, hypot(latest.x - point.x, latest.y - point.y) > 2 {
                        self.lookUp()
                    } else if icon == nil {
                        self.retryLookUp(at: point)
                    } else if self.panel.isVisible, icon?.bundleIdentifier == self.shownBundle {
                        self.followMagnification(at: point)
                    }
                }
            }
        }
    }

    /// A Dock that hides itself is still coming in when the pointer reaches the screen
    /// edge, so the lookup there finds no icon. The pointer then often rests on the
    /// icon with no further movement, so look again a few times.
    private func retryLookUp(at point: CGPoint) {
        retryWork?.cancel()
        retryWork = nil
        guard retries < Self.maxRetries, !panel.isVisible else { return }
        retries += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.latestPoint == point else { return }
            self.retryWork = nil
            self.lookUp()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval, execute: work)
    }

    /// How far from the Dock the pointer starts the read-ahead of window lists.
    private static let readAheadDistance: CGFloat = 200

    private static let maxRetries = 5
    private static let retryInterval: TimeInterval = 0.1

    /// Magnification keeps resizing the icon for a moment after the pointer stops, and
    /// the Dock's name label moves with it. Read the icon again until its frame holds
    /// still, so the preview ends exactly over the label.
    private func followMagnification(at point: CGPoint) {
        followWork?.cancel()
        followWork = nil
        guard steadyReads < Self.steadyReadsNeeded, DockHitTest.dockMagnifies else { return }
        // A small move during the last lookup didn't start another, so look again at
        // wherever the pointer is now.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.latestPoint != nil else { return }
            self.followWork = nil
            self.lookUp()
        }
        followWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followInterval, execute: work)
    }

    private static let steadyReadsNeeded = 5
    private static let followInterval: TimeInterval = 1.0 / 30

    private func found(_ icon: (bundleIdentifier: String, frame: CGRect)?, _ windows: [DockWindow], at point: CGPoint,
                       ignoringAim: Bool = false) {
        guard latestPoint != nil else { return }
        // Crossing another icon on the way up to the preview leaves the preview alone;
        // only stopping on it, or turning away, swaps or closes it.
        if panel.isVisible, let icon, icon.bundleIdentifier != shownBundle, !ignoringAim, isHeadingToPanel(from: point) {
            holdForAim()
            return
        }
        cancelAim()
        // One window needs no choosing; the Dock click already brings it forward.
        guard let icon, windows.count > 1 else {
            // On another icon the pointer isn't heading for the preview, so it goes at
            // once; between icons it gets the grace for moving up into the preview.
            if icon != nil { hide() } else { scheduleClose() }
            return
        }
        cancelClose()
        if panel.isVisible {
            // Moving along the Dock swaps the preview straight away.
            if shownBundle != icon.bundleIdentifier
                || panel.model.windows != Self.keepingOrder(of: panel.model.windows, updatedTo: windows) {
                present(icon, windows)
            } else if let shownIcon, !Self.isSame(shownIcon, icon.frame) {
                // Magnification moved the icon, and the Dock's name label with it.
                steadyReads = 0
                self.shownIcon = icon.frame
                panel.place(beside: icon.frame, edge: DockHitTest.dockEdge, magnified: DockHitTest.dockMagnifies)
            } else {
                steadyReads += 1
            }
            return
        }
        // Straight away: the lookup that got here takes a few milliseconds.
        present(icon, windows)
        confirmShown()
    }

    /// The preview opened from window lists read a moment ago. Read the app again and
    /// update or close the preview if a window came or went meanwhile.
    private func confirmShown() {
        guard let bundleIdentifier = shownBundle, let icon = shownIcon else { return }
        // Apart from the lookups, which keep following the pointer meanwhile.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, recentWindows] in
            let windows = recentWindows.windows(of: bundleIdentifier, maxAge: 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.panel.isVisible, self.shownBundle == bundleIdentifier else { return }
                    if windows.count < 2 {
                        self.hide()
                    } else if self.panel.model.windows != Self.keepingOrder(of: self.panel.model.windows, updatedTo: windows) {
                        self.present((bundleIdentifier, self.shownIcon ?? icon), windows)
                    }
                }
            }
        }
    }

    private func present(_ icon: (bundleIdentifier: String, frame: CGRect), _ windows: [DockWindow]) {
        // A lookup that set off before Mission Control opened.
        guard !missionControl.isOpen else { return hide() }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: icon.bundleIdentifier).first
        let model = panel.model
        let sameVisit = shownBundle == icon.bundleIdentifier && panel.isVisible
        if !sameVisit {
            liveWindow.stop()
            model.pictures = [:]
            model.selected = nil
            model.visit += 1
        }
        // Recency orders the cards when the preview opens; while it stays open they
        // keep their places, so nothing jumps under the pointer.
        let windows = sameVisit ? Self.keepingOrder(of: model.windows, updatedTo: windows) : windows
        if let peeking, let window = windows.first(where: { $0.id == peeking }),
           window != model.windows.first(where: { $0.id == peeking }) {
            showPeek(window)
        }
        shownBundle = icon.bundleIdentifier
        shownIcon = icon.frame
        model.appName = app?.localizedName ?? ""
        model.appIcon = recentWindows.icon(of: icon.bundleIdentifier) ?? app?.icon
        model.windows = windows
        if model.selected.map({ id in !windows.contains { $0.id == id } }) ?? true {
            model.selected = windows.first?.id
        }
        for window in windows where model.pictures[window.id] == nil {
            if let cached = thumbnails.cached(window.id) { model.pictures[window.id] = cached }
        }
        liveWindow.run()
        if model.animates != animates { model.animates = animates }
        peek.animates = animates
        steadyReads = 0
        panel.show(beside: icon.frame, edge: DockHitTest.dockEdge, magnified: DockHitTest.dockMagnifies)
        DockAutoHideHold.hold()
        if !sameVisit { hideDockLabel() }
        watchForMissionControl()
        pictureTask?.cancel()
        pictureTask = Task { [weak self, thumbnails] in
            for window in windows {
                guard !Task.isCancelled else { return }
                if let picture = await thumbnails.picture(of: window) {
                    guard !Task.isCancelled, let self, self.shownBundle == icon.bundleIdentifier else { return }
                    model.pictures[window.id] = picture
                    // A peek of a window that just changed follows it.
                    if self.peeking == window.id { self.showPeek(window) }
                }
            }
        }
    }

    nonisolated static func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    /// `updated`, with the windows already shown in their old places and new ones after them.
    nonisolated static func keepingOrder(of shown: [DockWindow], updatedTo updated: [DockWindow]) -> [DockWindow] {
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = shown.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        return kept + updated.filter { !keptIDs.contains($0.id) }
    }

    /// Long enough for the Dock to finish bringing the app forward.
    private static let afterDockClick: TimeInterval = 0.15
    /// Trackpad travel, in points, that moves the selection by one window.
    nonisolated private static let scrollStep: CGFloat = 30

    /// What a scroll event says, read on the tap's thread.
    struct Scroll: Sendable {
        let isContinuous: Bool
        /// Negative moves on, the way content moves when scrolled further down or right.
        let delta: CGFloat
        let isMomentum: Bool

        init(_ event: CGEvent) {
            isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            if isContinuous {
                delta = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                    + event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            } else {
                delta = CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                    + event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
            }
            isMomentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        }

        init(isContinuous: Bool, delta: CGFloat, isMomentum: Bool = false) {
            self.isContinuous = isContinuous
            self.delta = delta
            self.isMomentum = isMomentum
        }
    }

    private var scrollTravel: CGFloat = 0
    private var lastScroll: TimeInterval = 0

    /// Scrolling on the icon moves the selection: one window per wheel notch, or per
    /// short trackpad swipe, ignoring the glide after the fingers lift.
    private func scrolled(_ scroll: Scroll, at point: CGPoint) {
        guard panel.isVisible, let icon = shownIcon, icon.contains(point), !scroll.isMomentum else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastScroll > 0.3 { scrollTravel = 0 }
        lastScroll = now
        let (steps, travel) = Self.selectionSteps(for: scroll, carrying: scrollTravel)
        scrollTravel = travel
        guard steps != 0 else { return }
        let windows = panel.model.windows
        let current = windows.firstIndex { $0.id == panel.model.selected } ?? 0
        let next = min(max(current + steps, 0), windows.count - 1)
        guard windows.indices.contains(next), next != current else { return }
        panel.model.selected = windows[next].id
        bringSelectedForwardSoon()
    }

    private var scrollPick: DispatchWorkItem?
    /// A short pause first, so a quick scroll past several windows only brings the last one forward.
    private static let scrollPickDelay: TimeInterval = 0.08

    /// Scrolling picks a window and brings it forward too, so no click is needed.
    private func bringSelectedForwardSoon() {
        scrollPick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible,
                  let window = self.panel.model.windows.first(where: { $0.id == self.panel.model.selected }) else { return }
            // A minimized or hidden window stays put: scrolling only shows it in place,
            // and clicking the icon brings it back.
            if window.place == .minimized || window.place == .hidden {
                self.showPeek(window)
                return
            }
            self.endPeek()
            self.choose(window, keepOpen: true)
            // The app coming forward takes key from the panel, which would frost its glass.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.afterDockClick) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.panel.makeKey()
            }
        }
        scrollPick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollPickDelay, execute: work)
    }

    /// Windows to move the selection by, and the trackpad travel left over toward the next.
    nonisolated static func selectionSteps(for scroll: Scroll, carrying travel: CGFloat) -> (steps: Int, travel: CGFloat) {
        guard scroll.isContinuous else {
            return (scroll.delta < 0 ? 1 : scroll.delta > 0 ? -1 : 0, 0)
        }
        // A change of direction starts afresh.
        var total = (travel != 0 && (travel > 0) != (-scroll.delta > 0)) ? 0 : travel
        total += -scroll.delta
        let steps = Int(total / scrollStep)
        return (steps, total - CGFloat(steps) * scrollStep)
    }

    /// The selected window if a click on the icon should bring it forward; nil when the
    /// Dock's own click already does, for the front window on this desktop.
    private func pickedByIconClick() -> DockWindow? {
        let windows = panel.model.windows
        guard let selected = windows.first(where: { $0.id == panel.model.selected }) else { return nil }
        return selected == windows.first && selected.place == .here ? nil : selected
    }

    /// How far back the pointer's direction is read from.
    private static let headingWindow: TimeInterval = 0.08
    /// How long a pointer may rest on a crossed icon before that icon takes over.
    private static let aimGrace: TimeInterval = 0.15

    private func isHeadingToPanel(from point: CGPoint) -> Bool {
        guard let start = motion.first?.point else { return false }
        return Self.isHeading(from: point, direction: CGPoint(x: point.x - start.x, y: point.y - start.y),
                              toward: panelFrame.insetBy(dx: -12, dy: -12))
    }

    /// Whether a pointer at `point` moving along `direction` would reach `target`.
    nonisolated static func isHeading(from point: CGPoint, direction: CGPoint, toward target: CGRect) -> Bool {
        guard hypot(direction.x, direction.y) >= 2 else { return false }
        var near: CGFloat = 0, far = CGFloat.greatestFiniteMagnitude
        for (origin, step, low, high) in [(point.x, direction.x, target.minX, target.maxX),
                                          (point.y, direction.y, target.minY, target.maxY)] {
            if step == 0 {
                guard origin >= low, origin <= high else { return false }
                continue
            }
            let a = (low - origin) / step, b = (high - origin) / step
            near = max(near, min(a, b))
            far = min(far, max(a, b))
        }
        return near <= far
    }

    private func holdForAim() {
        guard aimWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.aimWork = nil
            guard let point = self.latestPoint else { return }
            // Still on its way: keep waiting.
            if let last = self.motion.last, ProcessInfo.processInfo.systemUptime - last.time < Self.headingWindow,
               self.isHeadingToPanel(from: point) {
                self.holdForAim()
                return
            }
            // The pointer stopped short of the preview: let the icon under it decide.
            self.lookupQueue.async { [weak self, recentWindows = self.recentWindows] in
                let icon = MissionControlWatch.windowManagerIsShowing() ? nil : DockHitTest.appIcon(at: point)
                let windows = icon.map { recentWindows.windows(of: $0.bundleIdentifier) } ?? []
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.latestPoint == point else { return }
                        self.found(icon, windows, at: point, ignoringAim: true)
                    }
                }
            }
        }
        aimWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.aimGrace, execute: work)
    }

    private func cancelAim() {
        aimWork?.cancel()
        aimWork = nil
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

    private func hide() {
        // A peek handed over to the window being chosen goes once that window is in front.
        if !handedOverPeek { endPeek() }
        fullPictures = [:]
        scrollPick?.cancel()
        scrollPick = nil
        cancelClose()
        cancelAim()
        pictureTask?.cancel()
        pictureTask = nil
        liveWindow.stop()
        shownBundle = nil
        shownIcon = nil
        retryWork?.cancel()
        retryWork = nil
        followWork?.cancel()
        followWork = nil
        missionControlCheck?.invalidate()
        missionControlCheck = nil
        if panel.isVisible { panel.orderOut(nil) }
        if hidingDockLabel, let location = CGEvent(source: nil)?.location, DockHitTest.isInDockStrip(location) {
            // Back where the pointer really is, before an auto-hiding Dock is let go, so it
            // doesn't hide under the pointer.
            Self.postToDock(location)
        }
        hidingDockLabel = false
        DockAutoHideHold.release()
    }

    private func watchForMissionControl() {
        guard missionControlCheck == nil else { return }
        missionControlCheck = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lookupQueue.async { [weak self] in
                    guard MissionControlWatch.windowManagerIsShowing() else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.hide() }
                    }
                }
            }
        }
    }

    /// The panel's frame in the top-left coordinates of mouse events.
    private var panelFrame: CGRect { topLeft(panel.glassFrame) }

    /// The icon, the preview and the gap between them.
    private var bridgeFrame: CGRect {
        guard let shownIcon, !panelFrame.isNull else { return .null }
        return shownIcon.union(panelFrame)
    }

    private func topLeft(_ frame: CGRect) -> CGRect {
        guard frame.width > 0 else { return .null }
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: Showing a window in place

    private lazy var peek = WindowPeek()
    private var peeking: CGWindowID? {
        didSet { liveWindow.shownInPlace = peeking }
    }
    private var peekWork: DispatchWorkItem?
    private var peekTask: Task<Void, Never>?
    private var fullPictures: [CGWindowID: CGImage] = [:]
    /// Resting on a card this long shows its window in place; moving on to another
    /// card while one shows swaps straight over.
    private static let peekDelay: TimeInterval = 0.25
    /// Time to cross the gap between cards without the peek going away.
    private static let peekLeaveGrace: TimeInterval = 0.15

    /// The card the pointer is on.
    private var pointedAt: CGWindowID? {
        didSet { liveWindow.hovered = pointedAt }
    }

    private func pointAt(_ window: DockWindow, _ isOn: Bool) {
        if isOn {
            pointedAt = window.id
            peekWork?.cancel()
            if peek.isVisible {
                showPeek(window)
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pointedAt == window.id else { return }
                self.showPeek(window)
            }
            peekWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDelay, execute: work)
        } else {
            // Cards report arriving and leaving in either order, and there's a gap between
            // them: the peek ends only once the pointer has been off every card a moment.
            guard pointedAt == window.id else { return }
            pointedAt = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekLeaveGrace) { [weak self] in
                guard let self, self.pointedAt == nil else { return }
                self.endPeek()
            }
        }
    }

    private func showPeek(_ window: DockWindow) {
        peekWork = nil
        // The window already in front is already there to see.
        if window.place == .here, Self.isFrontWindow(window.id) {
            if peeking != nil { endPeek() }
            return
        }
        // A live window's frames come at full resolution from the next one on, so it needs
        // no capture of its own.
        let live = liveWindow.latestFrame(of: window.id)
        guard panel.isVisible,
              let image = fullPictures[window.id] ?? live ?? panel.model.pictures[window.id] ?? thumbnails.cached(window.id)
        else { return }
        peeking = window.id
        peek.show(image, at: window.bounds, dimmed: window.place == .minimized || window.place == .hidden)
        guard fullPictures[window.id] == nil, live == nil else { return }
        let scale = NSScreen.screens.first { $0.frame.intersects(window.bounds) }?.backingScaleFactor ?? 2
        peekTask?.cancel()
        peekTask = Task { [weak self, thumbnails] in
            guard let full = await thumbnails.fullPicture(of: window, scale: scale), !Task.isCancelled,
                  let self, self.peeking == window.id else { return }
            self.fullPictures[window.id] = full
            self.peek.update(full)
        }
    }

    /// The longest to wait for an app to bring its window forward.
    private static let raiseTimeout: TimeInterval = 0.3
    /// A peek handed over to the window being brought forward, no longer following the cards.
    private var handedOverPeek = false

    /// Stops the peek following the pointer, leaving it up for now.
    private func detachPeek() {
        peekWork?.cancel()
        peekWork = nil
        peekTask?.cancel()
        peekTask = nil
        pointedAt = nil
        peeking = nil
        handedOverPeek = true
    }

    /// Takes down a handed-over peek once the real window is in front.
    private func retirePeek() {
        guard handedOverPeek else { return }
        handedOverPeek = false
        if peeking == nil { peek.hidePeek() }
    }

    private func endPeek() {
        handedOverPeek = false
        pointedAt = nil
        peekWork?.cancel()
        peekWork = nil
        peekTask?.cancel()
        peekTask = nil
        peeking = nil
        peek.hidePeek(animated: true)
    }

    // MARK: Going to a window

    private func choose(_ window: DockWindow, keepOpen: Bool = false) {
        // The peek of this window stays until the real one is in front, so nothing else
        // shows through for a frame in between.
        let handOver = peeking == window.id && peek.isVisible
        if handOver { detachPeek() } else { endPeek() }
        if !keepOpen { hide() }
        let finish: () -> Void = { [weak self] in if handOver { self?.retirePeek() } }
        // Where the window is now, not when the preview opened: moving between desktops
        // while the preview stays up changes which windows are here.
        if let spaceID = Self.otherDesktop(of: window), switchToSpace?(spaceID) == true {
            focusAfterSwitch = window
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusAfterSwitchTimeout) { [weak self] in
                guard let self, self.focusAfterSwitch == window else { return }
                self.focusAfterSwitch = nil
                self.raise(window, then: finish)
            }
            focusAfterSwitchDone = finish
            return
        }
        raise(window, then: finish)
    }

    /// Whether `id` is the front window on screen, looking past see-through overlays
    /// that cover a whole screen and this app's own windows.
    nonisolated private static func isFrontWindow(_ id: CGWindowID) -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map { $0.frame.size }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for entry in list where (entry[kCGWindowLayer as String] as? Int) == 0 {
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != own,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  !screens.contains(where: { bounds.width >= $0.width && bounds.height >= $0.height }) else { continue }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
        }
        return false
    }

    /// The desktop a window is on if it isn't one being shown, else nil.
    private static func otherDesktop(of window: DockWindow) -> UInt64? {
        let spaces = WindowSpacePrivateApis.spaces(for: window.id)
        let active = Set(WindowSpacePrivateApis.activeSpaceIDs().map { Int($0) })
        guard let space = spaces.first, spaces.isDisjoint(with: active) else { return nil }
        return UInt64(space)
    }

    /// Shows the app if hidden, restores the window if minimized, and brings it to the front.
    private func raise(_ window: DockWindow, then done: @escaping () -> Void = {}) {
        guard let app = NSRunningApplication(processIdentifier: window.processIdentifier) else { done(); return }
        if app.isHidden { app.unhide() }
        actionQueue.async {
            if let element = DockWindows.element(for: window) {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
            // An app's window only comes in front of other apps' windows once the app is
            // active, and apps take a moment to act on that. The peek stays until the
            // window really is in front, then goes at once, so neither the window behind
            // nor a doubled shadow shows for a frame.
            DispatchQueue.main.async { _ = app.activate() }
            let deadline = Date().addingTimeInterval(Self.raiseTimeout)
            while !Self.isFrontWindow(window.id), Date() < deadline { usleep(4_000) }
            DispatchQueue.main.async { done() }
        }
    }
}

/// The last app's window list. Listing windows reads every window on the Mac, so
/// the stream of lookups while the pointer moves over one icon shares a recent list.
private final class RecentWindows: @unchecked Sendable {
    private static let maxAge: TimeInterval = 0.5
    private let lock = NSLock()
    private var entries: [String: (windows: [DockWindow], at: TimeInterval)] = [:]
    private var readingAhead = false
    /// App icons, loaded and decoded ahead, since the first use of each is slow.
    private var icons: [String: NSImage] = [:]

    func icon(of bundleIdentifier: String) -> NSImage? { lock.withLock { icons[bundleIdentifier] } }

    /// Windows to open a preview with straight away. A list read ahead that has two or
    /// more windows serves at any age, since the preview checks it again once it opens;
    /// one with fewer serves only while recent, so a second window opened since then
    /// still opens the preview.
    func windowsToOpen(_ bundleIdentifier: String) -> [DockWindow] {
        cachedWindowsToOpen(bundleIdentifier) ?? windows(of: bundleIdentifier, maxAge: 0)
    }

    /// The same, from what was read already, or nil when the app must be asked.
    func cachedWindowsToOpen(_ bundleIdentifier: String) -> [DockWindow]? {
        let now = ProcessInfo.processInfo.systemUptime
        guard let entry = lock.withLock({ entries[bundleIdentifier] }),
              entry.windows.count > 1 || now - entry.at < Self.maxAge else { return nil }
        return entry.windows
    }

    func windows(of bundleIdentifier: String, maxAge: TimeInterval = RecentWindows.maxAge) -> [DockWindow] {
        let now = ProcessInfo.processInfo.systemUptime
        if let entry = lock.withLock({ entries[bundleIdentifier] }), now - entry.at < maxAge { return entry.windows }
        let windows = DockWindows.windows(bundleIdentifier: bundleIdentifier)
        lock.withLock { entries[bundleIdentifier] = (windows, now) }
        return windows
    }

    /// Reads every running app's windows in one pass, so the preview for whichever icon
    /// the pointer reaches first is ready at once. Skips apps read recently.
    func readAhead() {
        let now = ProcessInfo.processInfo.systemUptime
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let running = Set(regular.compactMap(\.bundleIdentifier))
        for app in regular {
            guard let bundleIdentifier = app.bundleIdentifier, lock.withLock({ icons[bundleIdentifier] }) == nil,
                  let icon = app.icon else { continue }
            // Decode the size a card shows, so the first card to draw it doesn't.
            var rect = CGRect(x: 0, y: 0, width: 96, height: 96)
            _ = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            lock.withLock { icons[bundleIdentifier] = icon }
        }
        let stale = lock.withLock { () -> [String]? in
            guard !readingAhead else { return nil }
            entries = entries.filter { running.contains($0.key) }
            let stale = Array(running.filter { entries[$0].map { now - $0.at >= Self.maxAge * 0.8 } ?? true })
            readingAhead = !stale.isEmpty
            return stale
        }
        guard let stale, !stale.isEmpty else { return }
        let read = DockWindows.windows(bundleIdentifiers: stale)
        let done = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            for bundleIdentifier in stale { entries[bundleIdentifier] = (read[bundleIdentifier] ?? [], done) }
            readingAhead = false
        }
    }
}
