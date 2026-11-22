import ApplicationServices
import CoreGraphics
import Foundation

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64
typealias CGSSpaceMask = UInt64

@_silgen_name("CGSMainConnectionID")
nonisolated private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopySpacesForWindows")
nonisolated private func CGSCopySpacesForWindows(_ cid: CGSConnectionID,
                                                 _ mask: CGSSpaceMask,
                                                 _ windowIDs: CFArray) -> CFArray?

@_silgen_name("CGSCopyManagedDisplaySpaces")
nonisolated private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

@_silgen_name("CGSHWCaptureWindowList")
nonisolated private func CGSHWCaptureWindowList(_ cid: CGSConnectionID,
                                                _ windowList: UnsafeMutablePointer<CGWindowID>,
                                                _ windowCount: UInt32,
                                                _ options: UInt32) -> Unmanaged<CFArray>?

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
nonisolated private func _AXUIElementGetWindow(_ axUIElement: AXUIElement,
                                               _ windowID: inout CGWindowID) -> AXError

enum WindowSpacePrivateApis {
    nonisolated static func windowID(for axWindow: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    /// A picture of one window straight from the window server, without its shadow:
    /// about 16 ms against ScreenCaptureKit's 45 ms plus a window listing, and it also
    /// works for windows on other desktops and of hidden apps. Blocks, so call it off
    /// the main thread. `bestResolution` gives the screen's pixels, otherwise points.
    nonisolated static func captureWindow(_ windowID: CGWindowID, bestResolution: Bool) -> CGImage? {
        // kCGSCaptureIgnoreGlobalClipShape, plus kCGSCaptureBestResolution or kCGSWindowCaptureNominalResolution.
        let options: UInt32 = (1 << 11) | (bestResolution ? 1 << 8 : 1 << 9)
        var id = windowID
        let images = CGSHWCaptureWindowList(CGSMainConnectionID(), &id, 1, options)?.takeRetainedValue() as? [CGImage]
        guard let image = images?.first, image.width > 1, image.height > 1 else { return nil }
        return image
    }

    nonisolated static func spaces(for windowID: CGWindowID) -> Set<Int> {
        // Current, other and user spaces. Setting every bit makes macOS 27 report
        // ordinary windows on no space and invisible helper windows on the current one.
        let allSpacesMask: CGSSpaceMask = 0x7
        let ids: CFArray = [NSNumber(value: UInt32(windowID))] as CFArray
        guard let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(),
                                                   allSpacesMask,
                                                   ids) as? [NSNumber] else {
            return []
        }
        return Set(spaces.map { Int($0.uint64Value) })
    }

    /// The space showing on each display right now. Not cached: it changes with every switch.
    nonisolated static func activeSpaceIDs() -> Set<CGSSpaceID> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else {
            return []
        }
        return Set(displays.compactMap { display in
            guard let current = display["Current Space"] as? [String: Any] else { return nil }
            return (current["id64"] as? NSNumber)?.uint64Value ?? (current["id64"] as? UInt64)
        })
    }
}
