import CoreGraphics
import CoreFoundation
import Darwin

// Adapted from InSpace (MIT, Gameslayer999), which ports jurplel/InstantSpaceSwitcher
// (MIT): Sources/ISS/ISS.c (iss_post_modern_dock_swipe) and event_serialize.c.

/// A synthetic trackpad swipe so fast that the Dock switches desktops with
/// nothing left to animate.
enum DockSwipe {
    private static func field(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }

    /// Natural scrolling flips the sign the Dock reads.
    static func naturalScrolling() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let natural = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString,
                                                      kCFPreferencesAnyApplication, &valid)
        return !valid.boolValue || natural
    }

    /// An ended-phase fling this fast commits the switch with nothing to animate.
    static let velocity = 9999.0

    /// Posts began/changed/ended together, so a gesture is never left half-open.
    /// Returns false, having posted nothing, if an event can't be built.
    static func post(right: Bool, steps: Int = 1, naturalScrolling: Bool) -> Bool {
        let sign = (right ? -1.0 : 1.0) * (naturalScrolling ? 1 : -1)
        var events: [CGEvent] = []
        for _ in 0..<max(1, steps) {
            for phase: Int64 in [1, 2, 4] { // began, changed, ended
                guard let pair = gesture(phase: phase, progress: sign * 0.000016,
                                         velocity: phase == 4 ? sign * velocity * Double(steps) : 0)
                else { return false }
                events += pair
            }
        }
        for event in events { event.post(tap: .cgSessionEventTap) }
        return true
    }

    /// One DockControl swipe event plus the companion gesture event the Dock requires.
    private static func gesture(phase: Int64, progress: Double, velocity: Double) -> [CGEvent]? {
        guard let e = CGEvent(source: nil) else { return nil }
        e.setIntegerValueField(field(55), value: 30)    // kCGSEventDockControl
        e.setIntegerValueField(field(110), value: 23)   // kIOHIDEventTypeDockSwipe
        e.setIntegerValueField(field(132), value: phase)
        e.setIntegerValueField(field(123), value: 1)    // horizontal
        e.setDoubleValueField(field(124), value: progress)
        e.setIntegerValueField(field(134), value: phase)
        e.setDoubleValueField(field(138), value: 3.0)
        e.setDoubleValueField(field(169), value: Double(mach_absolute_time()))
        e.setDoubleValueField(field(125), value: 0.1)   // position x
        if velocity != 0 { e.setDoubleValueField(field(129), value: velocity) }
        guard let swipe = augment(e), let companion = CGEvent(source: nil) else { return nil }
        companion.setIntegerValueField(field(55), value: 29) // kCGSEventGesture
        return [swipe, companion]
    }

    /// macOS 27's Dock only honours a synthetic swipe carrying the raw IOHID
    /// fluid-touch (+velocity) payload, appended to the event data under tag 4205.
    private static func augment(_ e: CGEvent) -> CGEvent? {
        guard let cf = e.data else { return nil }
        let data = [UInt8](UnsafeBufferPointer(start: CFDataGetBytePtr(cf), count: CFDataGetLength(cf)))
        guard data.starts(with: [0, 0, 0, 2]) else { return nil } // serialization format v2
        let phase = e.getIntegerValueField(field(132))
        let velX = e.getDoubleValueField(field(129)), velY = e.getDoubleValueField(field(130))
        let withVelocity = velX != 0 || velY != 0 || phase == 4
        var p: [UInt8] = []
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { p.append(contentsOf: $0) } }
        func fixed(_ v: Double) -> Int32 { // 16.16, never rounding a non-zero value to zero
            let f = Int32(clamping: Int64(v * 65536))
            return f == 0 && v != 0 ? (v > 0 ? 1 : -1) : f
        }
        // IOHIDSystemQueueElementHeader: timestamp, sender, options, attribute length, event count
        put(e.timestamp != 0 ? e.timestamp : mach_absolute_time()); put(UInt64(0)); put(UInt32(0)); put(UInt32(0))
        put(UInt32(withVelocity ? 2 : 1))
        // IOHIDFluidTouchGestureData: base (size, type 23, phase<<24, depth 0), position, mask, motion, flavor 3, progress
        put(UInt32(40)); put(UInt32(23)); put(UInt32(phase & 0xFF) << 24); put(UInt32(0))
        put(fixed(e.getDoubleValueField(field(125)))); put(fixed(e.getDoubleValueField(field(126)))); put(Int32(0))
        put(UInt32(truncatingIfNeeded: e.getIntegerValueField(field(115))))
        put(UInt16(truncatingIfNeeded: e.getIntegerValueField(field(123)))); put(UInt16(3))
        put(fixed(e.getDoubleValueField(field(124))))
        if withVelocity { // IOHIDVelocityEventData: base (size, type 9, options, depth 1), velocity xyz
            put(UInt32(28)); put(UInt32(9)); put(UInt32(0)); put(UInt32(1))
            put(fixed(velX)); put(fixed(velY)); put(Int32(0))
        }
        var out = data
        out.append(contentsOf: [UInt8(p.count >> 8 & 0xFF), UInt8(p.count & 0xFF), UInt8(4205 >> 8), UInt8(4205 & 0xFF)])
        out += p
        return CGEvent(withDataAllocator: nil, data: CFDataCreate(nil, out, out.count))
    }
}

/// Private SkyLight calls, resolved at runtime so a macOS that drops one leaves
/// switching native instead of crashing.
enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }

    private static let mainConnectionID = sym("CGSMainConnectionID", (@convention(c) () -> Int32).self)
    private static let getActiveSpace = sym("CGSGetActiveSpace", (@convention(c) (Int32) -> UInt64).self)
    private static let copyManagedDisplaySpaces = sym("CGSCopyManagedDisplaySpaces",
        (@convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?).self)
    private static let copyActiveMenuBarDisplayIdentifier = sym("CGSCopyActiveMenuBarDisplayIdentifier",
        (@convention(c) (Int32) -> Unmanaged<CFString>?).self)

    static var available: Bool {
        mainConnectionID != nil && getActiveSpace != nil
            && copyManagedDisplaySpaces != nil && copyActiveMenuBarDisplayIdentifier != nil
    }

    struct Spaces {
        let display: String
        /// Mission Control order; full-screen apps have their own spaces.
        let ids: [UInt64]
        let isDesktop: [Bool]
        let current: Int
        var count: Int { isDesktop.count }
    }

    /// The menu-bar display's spaces and the active one, from live window-server state.
    static func spaces() -> Spaces? {
        guard available else { return nil }
        let cid = mainConnectionID!()
        guard let display = copyActiveMenuBarDisplayIdentifier!(cid)?.takeRetainedValue() as String?,
              let all = copyManagedDisplaySpaces!(cid, nil)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        let active = getActiveSpace!(cid)
        for entry in all where entry["Display Identifier"] as? String == display {
            let spaces = entry["Spaces"] as? [[String: Any]] ?? []
            let ids = spaces.map { $0["ManagedSpaceID"] as? UInt64 ?? 0 }
            guard let current = ids.firstIndex(of: active) else { return nil }
            // Type 0 is a desktop; 4 is a full-screen app.
            return Spaces(display: display, ids: ids,
                          isDesktop: spaces.map { ($0["type"] as? Int ?? 0) == 0 }, current: current)
        }
        return nil
    }
}
