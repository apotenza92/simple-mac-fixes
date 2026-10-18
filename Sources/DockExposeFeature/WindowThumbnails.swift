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

    /// A fresh picture if one can be taken, otherwise the last one.
    func picture(of window: DockWindow) async -> CGImage? {
        if let entry = cache[window.id], Date().timeIntervalSince(entry.at) < Self.refreshInterval { return entry.image }
        guard Self.isAllowed, window.place != .minimized, let scWindow = await scWindow(window.id) else {
            return cache[window.id]?.image
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        let scale = min(1, Self.maximumPixels / max(window.bounds.width, window.bounds.height, 1)) * 2
        configuration.width = max(1, Int(window.bounds.width * scale))
        configuration.height = max(1, Int(window.bounds.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        else { return cache[window.id]?.image }
        cache[window.id] = (image, Date())
        if cache.count > 300, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
        return image
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
