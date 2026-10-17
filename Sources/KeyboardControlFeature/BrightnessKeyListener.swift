import Foundation
import IOKit.hid

/// Reads F1/F2 at HID level when no built-in panel is active. In that setup
/// macOS may discard brightness keys before they become media-key events.
public final class BrightnessKeyListener {
    private var manager: IOHIDManager?
    private var isFunctionHeld = false
    private let handler: (_ isUp: Bool) -> Void

    public init(handler: @escaping (_ isUp: Bool) -> Void) {
        self.handler = handler
    }

    public static var hasPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    public var isRunning: Bool { manager != nil }

    @discardableResult
    public static func requestPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 0x01,
            kIOHIDDeviceUsageKey: 0x06,
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [
            [kIOHIDElementUsagePageKey: 0x07],
            [kIOHIDElementUsagePageKey: 0x0C],
            [kIOHIDElementUsagePageKey: 0xFF],
            [kIOHIDElementUsagePageKey: 0xFF01],
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<BrightnessKeyListener>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess || status == kIOReturnExclusiveAccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        self.manager = manager
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private var isBrightnessIntent: Bool {
        isFunctionHeld == UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) == 1

        if usage == 0x03, page == 0xFF || page == 0xFF01 {
            isFunctionHeld = pressed
            return
        }
        guard pressed else { return }
        switch (page, usage) {
        case (0x07, 0x3A): if isBrightnessIntent { handler(false) }
        case (0x07, 0x3B): if isBrightnessIntent { handler(true) }
        case (0x0C, 0x70): handler(false)
        case (0x0C, 0x6F): handler(true)
        default: break
        }
    }

    deinit { stop() }
}
