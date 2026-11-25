import CoreGraphics
import Foundation

/// Turns a drag's pointer moves into moves with no button for every app, and tells when
/// the button came up.
///
/// Used from the press on a maximized window's title bar until the drag ends. While
/// the pointer covers the first points, the window's app gets no drag and so leaves the
/// window where it is. Once the window comes away, this feature moves it, and the app
/// must not: the app moves a dragged window for each pointer move it gets, from a
/// start it keeps, and a move that reaches it soon after a frame written from outside
/// puts the window back where that start says (measured: 80 to 170 points off for
/// single frames).
///
/// No move is dropped: macOS moves the pointer on screen only with the moves that get
/// through a session tap. The tap is on only during such a drag, on a thread of its own.
final class DragEventGate: @unchecked Sendable {
    /// Marks the moves this feature sends to the window's app itself.
    static let ownEventMarker: Int64 = 0x534D_4647

    private let lock = NSLock()
    private var port: CFMachPort?
    private var isHolding = false
    private var releaseLocation: CGPoint?
    private var currentGeneration = 0

    /// Counts the calls of `begin`, so that the end of one drag does not open the gate
    /// of the next.
    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    /// False when the tap cannot be made: the caller then restores with no animation.
    func begin() -> Bool {
        guard let port = startedPort() else {
            return false
        }
        // The tap is switched inside the lock, so an `end` of the last drag cannot switch
        // it off after this `begin` switched it on.
        lock.lock()
        isHolding = true
        releaseLocation = nil
        currentGeneration += 1
        CGEvent.tapEnable(tap: port, enable: true)
        lock.unlock()
        return true
    }

    /// With a generation, does nothing when `begin` ran again since.
    func end(generation: Int? = nil) {
        lock.lock()
        if let generation, generation != currentGeneration {
            lock.unlock()
            return
        }
        isHolding = false
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        lock.unlock()
    }

    /// Where the button came up, once it did.
    var released: CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return releaseLocation
    }

    private func startedPort() -> CFMachPort? {
        lock.lock()
        defer { lock.unlock() }
        if let port {
            return port
        }

        let mask = CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let gate = Unmanaged<DragEventGate>.fromOpaque(userInfo).takeUnretainedValue()
            return gate.handle(type, event) ? Unmanaged.passUnretained(event) : nil
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }
        CGEvent.tapEnable(tap: port, enable: false)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.apotenza.SimpleMacFixes.dragEventGate"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.port = port
        return port
    }

    /// False drops the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = isHolding ? self.port : nil
            lock.unlock()
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return true
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEventMarker else {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        guard isHolding else {
            return true
        }
        if type == .leftMouseUp {
            releaseLocation = event.location
            return true
        }
        // A move with no button means the drag ended, also when this tap did not see
        // the release (it was off for a moment).
        if type == .mouseMoved {
            if releaseLocation == nil {
                releaseLocation = event.location
            }
            return true
        }
        // A move after the button came up belongs to another drag.
        if releaseLocation != nil {
            return true
        }
        // The move goes on as a move with no button, not dropped: macOS moves the
        // pointer on screen only with the moves that get through a session tap, so a
        // real mouse's pointer froze while the window waited for it (a test program's
        // posted moves place the pointer themselves and did not show this). As a plain
        // move, the app does not drag the window with it.
        event.type = .mouseMoved
        return true
    }

    /// Tells the app that owns the dragged window that the button came up at
    /// `location`, which ends the app's own drag of the window. The button itself
    /// stays as it is. Posted at session level: this tap lets it through.
    static func sendRelease(at location: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: ownEventMarker)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cgSessionEventTap)
    }

}
