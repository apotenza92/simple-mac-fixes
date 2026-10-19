import AppKit
import ScreenCaptureKit

/// Pictures of windows for the Dock previews. Needs Screen Recording; without
/// it every request returns nil and the preview shows the app icon instead.
///
/// The last good picture of each window is kept, so a window that can't be
/// captured right now, such as a minimized one, still shows how it looked.
@MainActor
final class WindowThumbnails {
    /// Long side of a picture, in pixels; enough for a sharp card on Retina.
    private static let maximumPixels: CGFloat = 640
    /// Re-capture at most this often while a preview stays open.
    private static let refreshInterval: TimeInterval = 1

    private var cache: [CGWindowID: (image: CGImage, at: Date)] = [:]
    private var shareable: (content: SCShareableContent, at: Date)?

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ id: CGWindowID) -> CGImage? { cache[id]?.image }

    /// The next request takes a fresh picture, for a window that just changed.
    /// The old one stays as the fallback, since a minimized window can't be captured.
    func expire(_ id: CGWindowID) {
        if let entry = cache[id] { cache[id] = (entry.image, .distantPast) }
    }

    /// A fresh picture if one can be taken, otherwise the last one.
    func picture(of window: DockWindow) async -> CGImage? {
        if let entry = cache[window.id], Date().timeIntervalSince(entry.at) < Self.refreshInterval { return entry.image }
        guard Self.isAllowed, window.place != .minimized, let scWindow = await scWindow(window.id) else {
            return cache[window.id]?.image
        }
        let size = scWindow.frame.size
        let scale = Self.maximumPixels / max(size.width, size.height, 1)
        guard let image = await capture(scWindow, scale: scale) else { return cache[window.id]?.image }
        cache[window.id] = (image, Date())
        if cache.count > 300, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
        return image
    }

    /// The window at its full size on screen, for showing it in place.
    func fullPicture(of window: DockWindow, scale: CGFloat) async -> CGImage? {
        guard Self.isAllowed, window.place != .minimized, let scWindow = await scWindow(window.id) else { return nil }
        return await capture(scWindow, scale: scale)
    }

    private func capture(_ scWindow: SCWindow, scale: CGFloat) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        // The window's size right now, and its content stretched to fill the picture,
        // so a window on a standard screen or one just resized isn't drawn small in a corner.
        let size = scWindow.frame.size
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func scWindow(_ id: CGWindowID) async -> SCWindow? {
        if let shareable, Date().timeIntervalSince(shareable.at) < 1,
           let window = shareable.content.windows.first(where: { $0.windowID == id }) {
            return window
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return nil }
        shareable = (content, Date())
        return content.windows.first { $0.windowID == id }
    }
}
