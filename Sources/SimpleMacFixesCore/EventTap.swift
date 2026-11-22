import CoreGraphics
import Foundation

/// An active session event tap, on the main run loop or on a thread of its own.
///
/// Each feature owns its own tap so a slow or failing feature cannot stall
/// events that belong to another one. Every event of the tap's types waits for its
/// handler, so a handler that keeps no main-thread state runs on its own thread
/// (`ownThread`), where work on the main thread cannot delay it. Its callback holds the
/// tap unretained, so a tap on its own thread lives as long as the app.
public final class EventTap: @unchecked Sendable {
    /// Modify the event in place if needed; return false to drop it.
    public typealias Handler = (CGEventType, CGEvent) -> Bool

    private let mask: CGEventMask
    private let ownThread: Bool
    private let handler: Handler
    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    public init(types: [CGEventType], ownThread: Bool = false, handler: @escaping Handler) {
        mask = types.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
        self.ownThread = ownThread
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { lock.withLock { port != nil } }

    /// Fails while the app lacks Accessibility access.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type, event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        lock.withLock {
            self.port = port
            self.source = source
        }
        if ownThread {
            let ready = DispatchSemaphore(value: 0)
            let thread = Thread { [weak self] in
                let runLoop = CFRunLoopGetCurrent()!
                CFRunLoopAddSource(runLoop, source, .commonModes)
                self?.lock.withLock { self?.runLoop = runLoop }
                ready.signal()
                CFRunLoopRun()
            }
            thread.name = "com.apotenza.SimpleMacFixes.eventTap"
            thread.qualityOfService = .userInteractive
            thread.start()
            ready.wait()
        } else {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    public func stop() {
        let (port, source, runLoop) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?) in
            defer {
                self.port = nil
                self.source = nil
                self.runLoop = nil
            }
            return (self.port, self.source, self.runLoop)
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        } else if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event) ? Unmanaged.passUnretained(event) : nil
    }
}
