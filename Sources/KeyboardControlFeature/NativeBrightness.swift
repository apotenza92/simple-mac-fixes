import CoreGraphics
import Foundation

/// Optional native brightness support; software shades never touch built-in panels.
enum NativeBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getter: Get? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setter: Set? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    static func get(_ id: CGDirectDisplayID) -> Float? {
        guard let getter, setter != nil else { return nil }
        var value: Float = 0
        guard getter(id, &value) == 0, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    static func set(_ id: CGDirectDisplayID, percent: Int) -> Bool {
        setter?(id, Float(Level.clamp(percent)) / 100) == 0
    }
}
