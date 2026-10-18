import AppKit
import ScreenCaptureKit

/// Reads where the Dock drew its own name bubble, from the Dock's window alone,
/// where everything but the Dock is transparent. The Dock's placement varies by
/// up to a point from icon to icon, so copying the real one is the only way to
/// land exactly on it. Needs Screen Recording; returns nil without it.
enum NativeBubbleLocator {
    /// The bubble body without its tip, in top-left screen coordinates.
    static func locate(near icon: CGRect, edge: String) async -> CGRect? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let dock = content.windows.first(where: {
                  $0.owningApplication?.bundleIdentifier == "com.apple.dock" && $0.windowLayer == 20
                      && $0.frame.contains(icon)
              }) else { return nil }
        // Where the bubble can be: above the icon, or beside it on a side Dock.
        let search: CGRect = switch edge {
        case "left": CGRect(x: icon.maxX, y: icon.midY - 30, width: 700, height: 60)
        case "right": CGRect(x: icon.minX - 700, y: icon.midY - 30, width: 700, height: 60)
        default: CGRect(x: icon.midX - 400, y: icon.minY - 60, width: 800, height: 58)
        }
        // Whole points, so every captured pixel maps onto the screen's pixel grid.
        let region = search.intersection(dock.frame).integral
        guard !region.isNull, region.width > 10, region.height > 10 else { return nil }
        let scale = NSScreen.screens.first { $0.frame.width >= dock.frame.width }?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: region.minX - dock.frame.minX, y: region.minY - dock.frame.minY,
                                          width: region.width, height: region.height)
        configuration.width = Int(region.width * scale)
        configuration.height = Int(region.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: dock), configuration: configuration)
        else { return nil }
        guard let body = bodyRect(in: image, vertical: edge == "left" || edge == "right") else { return nil }
        // The image may not come back at exactly the requested size; measure against what it is.
        let xScale = CGFloat(image.width) / region.width, yScale = CGFloat(image.height) / region.height
        return CGRect(x: region.minX + body.minX / xScale, y: region.minY + body.minY / yScale,
                      width: body.width / xScale, height: body.height / yScale)
    }

    /// A picture of the screen exactly as it is in `rect`, leaving out this app's own
    /// windows: the Dock's bubble with the blurred background behind its glass.
    static func snapshot(of rect: CGRect) async -> (image: CGImage, rect: CGRect)? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        let region = rect.integral
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) })
        else { return nil }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let scale = NSScreen.screens.first { $0.frame.width == display.frame.width }?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: region.minX - display.frame.minX, y: region.minY - display.frame.minY,
                                          width: region.width, height: region.height)
        configuration.width = Int(region.width * scale)
        configuration.height = Int(region.height * scale)
        configuration.showsCursor = false
        // The display's own colour space, so the copy's colours come back unchanged.
        if let space = CGDisplayCopyColorSpace(display.displayID).name { configuration.colorSpaceName = space }
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        else { return nil }
        return (image, region)
    }

    /// The bubble body in image pixels: the opaque area, leaving out the narrower tip.
    static func bodyRect(in image: CGImage, vertical: Bool) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let opaque = { (x: Int, y: Int) in pixels[(y * width + x) * 4 + 3] > 40 }
        // Along the Dock's direction, count opaque pixels in each line across the bubble.
        let lines = vertical ? width : height, span = vertical ? height : width
        var counts = [Int](repeating: 0, count: lines)
        var ranges = [(Int, Int)?](repeating: nil, count: lines)
        for line in 0..<lines {
            var first = -1, last = -1
            for position in 0..<span where vertical ? opaque(line, position) : opaque(position, line) {
                if first < 0 { first = position }
                last = position
                counts[line] += 1
            }
            if first >= 0 { ranges[line] = (first, last) }
        }
        guard let widest = counts.max(), widest > 20 else { return nil }
        // The body: the run of lines at least half the widest, which excludes the tip.
        let body = counts.indices.filter { counts[$0] * 2 >= widest }
        guard let start = body.first, let end = body.last else { return nil }
        let across = (start...end).compactMap { ranges[$0] }
        guard let low = across.map(\.0).min(), let high = across.map(\.1).max() else { return nil }
        // Rounded ends are thinner than half the widest line: grow to the first and last opaque lines.
        var top = start, bottom = end
        while top > 0, counts[top - 1] > 0, counts[top - 1] * 4 >= widest { top -= 1 }
        while bottom < lines - 1, counts[bottom + 1] > 0, counts[bottom + 1] * 4 >= widest { bottom += 1 }
        return vertical
            ? CGRect(x: top, y: low, width: bottom - top + 1, height: high - low + 1)
            : CGRect(x: low, y: top, width: high - low + 1, height: bottom - top + 1)
    }
}
