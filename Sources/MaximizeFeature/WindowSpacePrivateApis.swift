import ApplicationServices
import CoreGraphics

typealias CGSConnectionID = UInt32
typealias CGSSpaceMask = UInt64

private let kCGSAllSpacesMask: CGSSpaceMask = 0xFFFF_FFFF_FFFF_FFFF

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connectionID: CGSConnectionID,
                                     _ mask: CGSSpaceMask,
                                     _ windowIDs: CFArray) -> CFArray?

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ windowID: inout CGWindowID) -> AXError

enum WindowSpacePrivateApis {
    static func windowID(for window: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    static func spaces(for windowID: CGWindowID) -> Set<Int> {
        let windowIDs: CFArray = [NSNumber(value: UInt32(windowID))] as CFArray
        guard let spaces = CGSCopySpacesForWindows(
            CGSMainConnectionID(),
            kCGSAllSpacesMask,
            windowIDs
        ) as? [NSNumber] else {
            return []
        }
        return Set(spaces.map { Int($0.uint64Value) })
    }
}
