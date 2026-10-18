import CoreGraphics
import Foundation

/// Your keyboard shortcuts for moving left and right between desktops switch
/// instantly, without the slide, and Control-Option-Command-1…9 jumps to a desktop.
///
/// The keys are caught at the HID level, ahead of the window server's own
/// shortcut handling, so the system's settings never change and nothing needs
/// restoring, even after a crash. The tap runs on its own thread so a key press
/// never waits on the rest of the app. Adapted from InSpace (MIT).
public final class InstantSpacesFeature {
    /// How often the shortcuts are re-read, so changes in System Settings are picked up.
    private static let refreshInterval: CFTimeInterval = 10
    /// While the Dock is still landing earlier swipes it reports an in-between
    /// desktop; trust our own prediction until it has been quiet this long.
    private static let predictionWindow: CFAbsoluteTime = 1.0

    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private var refreshTimer: CFRunLoopTimer?

    // Touched only on the tap thread.
    private var shortcuts: [SpaceShortcut] = []
    private var naturalScrolling = true
    private var swallowedKeyDowns = Set<Int64>()
    private var predicted: (display: String, index: Int)?
    private var lastSwipe: CFAbsoluteTime = 0

    public init() {}

    public var isRunning: Bool { lock.withLock { port != nil } }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning, SkyLight.available else { return isRunning }
        let ready = DispatchSemaphore(value: 0)
        var started = false
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            started = self.installTap()
            ready.signal()
            if started { CFRunLoopRun() }
        }
        thread.name = "Simple Mac Fixes desktop shortcuts"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if started { lock.withLock { self.thread = thread } }
        return started
    }

    public func stop() {
        let (port, runLoop, timer) = lock.withLock { () -> (CFMachPort?, CFRunLoop?, CFRunLoopTimer?) in
            defer { self.port = nil; self.runLoop = nil; self.refreshTimer = nil; self.thread = nil }
            return (self.port, self.runLoop, self.refreshTimer)
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let timer { CFRunLoopTimerInvalidate(timer) }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Runs on the tap thread.
    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let feature = Unmanaged<InstantSpacesFeature>.fromOpaque(userInfo).takeUnretainedValue()
            return feature.handle(type, event) ? Unmanaged.passUnretained(event) : nil
        }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        refresh()
        // Pay the first-use costs now rather than on the first key press.
        _ = CGEvent(source: nil)?.data
        _ = SkyLight.spaces()
        let runLoop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + Self.refreshInterval,
                                                    Self.refreshInterval, 0, 0) { [weak self] _ in self?.refresh() }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.withLock {
            self.port = port
            self.runLoop = runLoop
            self.refreshTimer = timer
        }
        return true
    }

    private func refresh() {
        shortcuts = SpaceShortcuts.current()
        naturalScrolling = DockSwipe.naturalScrolling()
    }

    /// Returns false to swallow the key. Decides immediately; everything else passes untouched.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            // Swallow the release of a press we consumed, and only that.
            return swallowedKeyDowns.remove(key) == nil
        }
        guard let shortcut = SpaceShortcuts.match(keyCode: key, flags: event.flags, in: shortcuts) else { return true }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return !swallowedKeyDowns.contains(key)
        }
        guard perform(shortcut.action) else { return true }
        swallowedKeyDowns.insert(key)
        return false
    }

    /// False lets the system's own shortcut run instead.
    private func perform(_ action: SpaceShortcut.Action) -> Bool {
        guard let spaces = SkyLight.spaces() else { return false }
        var current = spaces.current
        if let predicted, predicted.display == spaces.display,
           CFAbsoluteTimeGetCurrent() - lastSwipe < Self.predictionWindow {
            current = predicted.index
        }
        guard let target = Self.target(for: action, current: current, spaces: spaces.isDesktop) else {
            // At an edge, or no such desktop: do nothing. Overshooting the last
            // desktop can leave the Dock stuck on a black screen.
            return true
        }
        guard target != current else { return true }
        guard DockSwipe.post(right: target > current, steps: abs(target - current),
                             naturalScrolling: naturalScrolling) else { return false }
        predicted = (spaces.display, target)
        lastSwipe = CFAbsoluteTimeGetCurrent()
        return true
    }

    /// Moves straight to a space on the menu-bar display, without the slide.
    /// False if the space isn't there, so the caller can fall back to the system.
    public static func switchInstantly(toSpace spaceID: UInt64) -> Bool {
        guard let spaces = SkyLight.spaces(), let target = spaces.ids.firstIndex(of: spaceID) else { return false }
        guard target != spaces.current else { return true }
        return DockSwipe.post(right: target > spaces.current, steps: abs(target - spaces.current),
                              naturalScrolling: DockSwipe.naturalScrolling())
    }

    /// The space index to move to, or nil if there is none in that direction.
    static func target(for action: SpaceShortcut.Action, current: Int, spaces isDesktop: [Bool]) -> Int? {
        switch action {
        case .left: return current > 0 ? current - 1 : nil
        case .right: return current + 1 < isDesktop.count ? current + 1 : nil
        // Wrapping jumps straight across in one go, never past either end.
        case .next: return isDesktop.count > 1 ? (current + 1) % isDesktop.count : nil
        case .previous: return isDesktop.count > 1 ? (current + isDesktop.count - 1) % isDesktop.count : nil
        case let .desktop(number):
            // Desktop N counts desktops only, skipping full-screen apps, as Mission Control labels them.
            let desktops = isDesktop.indices.filter { isDesktop[$0] }
            return number < desktops.count ? desktops[number] : nil
        }
    }
}
