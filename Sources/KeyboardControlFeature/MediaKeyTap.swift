import AppKit
import ApplicationServices

public final class MediaKeyTap {
    public typealias Handler = (_ key: MediaKey, _ fine: Bool) -> Void

    private static let systemDefined = UInt32(14)
    private static let auxiliaryButtons = Int16(8)

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler

    public var shouldConsumeVolume: () -> Bool = { false }
    public var shouldConsumeBrightness: () -> Bool = { false }
    public var shouldHandleBrightness: () -> Bool = { false }

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var isRunning: Bool { tap != nil }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << Self.systemDefined) | CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown,
           let key = MediaKeyEvent.decodeFunctionKey(keyCode: event.getIntegerValueField(.keyboardEventKeycode)),
           shouldHandleBrightness(),
           Self.shouldUseFunctionKeysForBrightness {
            handler(key, event.flags.contains(.maskShift))
            return shouldConsumeBrightness() ? nil : Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.systemDefined,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxiliaryButtons,
              let decoded = MediaKeyEvent.decode(data1: Int64(nsEvent.data1)) else {
            return Unmanaged.passUnretained(event)
        }

        if decoded.key.isBrightness {
            if decoded.isKeyDown, shouldHandleBrightness() {
                handler(decoded.key, event.flags.contains(.maskShift))
            }
            // Keep Apple’s built-in adjustment/HUD; suppress its unavailable
            // indicator when Simple Mac Fixes owns brightness on external-only setups.
            return shouldConsumeBrightness() ? nil : Unmanaged.passUnretained(event)
        }

        guard shouldConsumeVolume() else { return Unmanaged.passUnretained(event) }
        if decoded.isKeyDown { handler(decoded.key, event.flags.contains(.maskShift)) }
        return nil
    }

    private static var shouldUseFunctionKeysForBrightness: Bool {
        !UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
    }

    deinit { stop() }
}
