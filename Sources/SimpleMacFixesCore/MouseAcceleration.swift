import Foundation
import IOKit
import IOKit.hidsystem

/// The Pointer acceleration switch in System Settings › Mouse, set the way
/// System Settings sets it: the saved preference plus the live HID flag that
/// makes WindowServer use linear tracking. Trackpads are unaffected.
public enum MouseAcceleration {
    private static let preferenceKey = "com.apple.mouse.linear" as CFString
    private static let hidKey = "HIDUseLinearScalingMouseAcceleration" as CFString

    public static var isOff: Bool {
        CFPreferencesCopyValue(preferenceKey, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? false
    }

    /// Returns false if the change could not be applied straight away; the
    /// preference still takes effect at the next login.
    @discardableResult
    public static func setOff(_ off: Bool) -> Bool {
        CFPreferencesSetValue(preferenceKey, off as CFBoolean, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let system = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard system != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(system) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(system, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
        else { return false }
        defer { IOServiceClose(connection) }
        return IOHIDSetCFTypeParameter(connection, hidKey, off as CFBoolean) == KERN_SUCCESS
    }
}
