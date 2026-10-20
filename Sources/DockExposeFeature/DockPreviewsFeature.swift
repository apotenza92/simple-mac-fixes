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

    private lazy var panel: DockPreviewPanel = {
        let panel = DockPreviewPanel()
        panel.model.choose = { [weak self] window in self?.choose(window) }
        panel.model.control = { [weak self] control, window in self?.control(control, on: window) }
        panel.model.pointAt = { [weak self] window, isOn in self?.pointAt(window, isOn) }
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
    /// No preview while Mission Control or App Exposé is open: the Dock's icons are its own then.
    private let missionControl = MissionControlWatch()
    /// Looks for Mission Control opening while the preview shows; newer macOS doesn't announce it.
    private var missionControlCheck: Timer?
    private let lookupQueue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.dockPreviews", qos: .userInteractive)
    /// Only used on `lookupQueue`.
    private let recentWindows = RecentWindows()
    /// Window buttons and bringing windows forward wait on the app and on resizing, so
    /// they run apart from the lookups that follow the pointer.
    private let actionQueue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.dockPreviews.actions", qos: .userInitiated)

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var spaceObserver: NSObjectProtocol?

    private var shownBundle: String?
    private var latestPoint: CGPoint?
    private var lookupInFlight = false
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
        missionControl.opened = { [weak self] in self?.hide() }
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
        updateNameBubble(for: point)
        if panel.isVisible, panelFrame.insetBy(dx: -4, dy: -4).contains(point)
            || topLeft(nameBubble.frame).insetBy(dx: -4, dy: -4).contains(point) {
            cancelClose()
            cancelAim()
            return
        }
        guard DockHitTest.isInDockStrip(point) else {
            latestPoint = nil
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
        lookupQueue.async { [weak self, recentWindows] in
            let missionControlOpen = MissionControlWatch.windowManagerIsShowing()
            let icon = missionControlOpen ? nil : DockHitTest.appIcon(at: point)
            let windows = icon.map { recentWindows.windows(of: $0.bundleIdentifier) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lookupInFlight = false
                    if missionControlOpen {
                        self.hide()
                        return
                    }
                    self.found(icon, windows, at: point)
                    if let latest = self.latestPoint, hypot(latest.x - point.x, latest.y - point.y) > 2 { self.lookUp() }
                }
            }
        }
    }

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
            }
            return
        }
        // Straight away: the lookup that got here takes a few milliseconds.
        present(icon, windows)
    }

    private func present(_ icon: (bundleIdentifier: String, frame: CGRect), _ windows: [DockWindow]) {
        // A lookup that set off before Mission Control opened.
        guard !missionControl.isOpen else { return hide() }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: icon.bundleIdentifier).first
        let model = panel.model
        let sameVisit = shownBundle == icon.bundleIdentifier && panel.isVisible
        if !sameVisit {
            model.pictures = [:]
            model.selected = nil
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
        model.appIcon = app?.icon
        model.windows = windows
        if model.selected.map({ id in !windows.contains { $0.id == id } }) ?? true {
            model.selected = windows.first?.id
        }
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

    /// The Dock shows a name for whichever icon the pointer is on, so ours waits until
    /// the pointer has left the Dock altogether and then takes over in the same spot.
    private func updateNameBubble(for point: CGPoint) {
        guard panel.isVisible, shownIcon != nil else { return }
        let inDock = DockHitTest.isInDockStrip(point)
        if inDock, nameBubble.isVisible {
            nameBubble.orderOut(nil)
        } else if !inDock, !nameBubble.isVisible {
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
                // The Dock fades its bubble out the moment the pointer leaves the icon, so
                // only a picture taken wholly while the pointer was on it counts.
                while !Task.isCancelled, self.shownIcon == icon, !self.nameBubble.isVisible {
                    let onIconBefore = Self.pointerIsOn(icon)
                    if let snapshot = await NativeBubbleLocator.snapshot(of: area), !Task.isCancelled,
                       self.shownIcon == icon, !self.nameBubble.isVisible, onIconBefore, Self.pointerIsOn(icon) {
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

    private static func pointerIsOn(_ icon: CGRect) -> Bool {
        guard let location = CGEvent(source: nil)?.location else { return false }
        return icon.contains(location)
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
        shownBundle = nil
        shownIcon = nil
        measureTask?.cancel()
        measuredBubble = nil
        bubbleSnapshot = nil
        missionControlCheck?.invalidate()
        missionControlCheck = nil
        if panel.isVisible { panel.orderOut(nil) }
        if nameBubble.isVisible { nameBubble.orderOut(nil) }
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

    private func topLeft(_ frame: CGRect) -> CGRect {
        guard frame.width > 0 else { return .null }
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: Showing a window in place

    private lazy var peek = WindowPeek()
    private var peeking: CGWindowID?
    private var peekWork: DispatchWorkItem?
    private var peekTask: Task<Void, Never>?
    private var fullPictures: [CGWindowID: CGImage] = [:]
    /// Resting on a card this long shows its window in place; moving on to another
    /// card while one shows swaps straight over.
    private static let peekDelay: TimeInterval = 0.25
    /// Time to cross the gap between cards without the peek going away.
    private static let peekLeaveGrace: TimeInterval = 0.15

    /// The card the pointer is on.
    private var pointedAt: CGWindowID?

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
        guard panel.isVisible, let image = fullPictures[window.id] ?? panel.model.pictures[window.id] ?? thumbnails.cached(window.id)
        else { return }
        peeking = window.id
        peek.show(image, at: window.bounds, dimmed: window.place == .minimized || window.place == .hidden)
        guard fullPictures[window.id] == nil else { return }
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
        peek.hidePeek()
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
    private var last: (bundleIdentifier: String, windows: [DockWindow], at: TimeInterval)?

    func windows(of bundleIdentifier: String, maxAge: TimeInterval = RecentWindows.maxAge) -> [DockWindow] {
        let now = ProcessInfo.processInfo.systemUptime
        if let last, last.bundleIdentifier == bundleIdentifier, now - last.at < maxAge { return last.windows }
        let windows = DockWindows.windows(bundleIdentifier: bundleIdentifier)
        last = (bundleIdentifier, windows, now)
        return windows
    }
}
