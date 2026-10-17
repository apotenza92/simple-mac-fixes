import CoreGraphics
import Foundation

/// An active session event tap on the main run loop.
///
/// Each feature owns its own tap so a slow or failing feature cannot stall
/// events that belong to another one.
public final class EventTap {
    /// Modify the event in place if needed; return false to drop it.
    public typealias Handler = (CGEventType, CGEvent) -> Bool

    private let mask: CGEventMask
    private let handler: Handler
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    public init(types: [CGEventType], handler: @escaping Handler) {
        mask = types.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { port != nil }

    /// Fails while the app lacks Accessibility access.
    @discardableResult
    public func start() -> Bool {
        guard port == nil else { return true }
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event) ? Unmanaged.passUnretained(event) : nil
    }
}
