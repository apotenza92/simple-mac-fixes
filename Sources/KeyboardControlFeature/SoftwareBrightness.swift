import AppKit
import CoreGraphics

/// A process-owned shade: quitting or crashing removes it without changing
/// display gamma tables, color profiles, or the monitor's backlight.
@MainActor
final class SoftwareBrightness {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    var displayIDs: [CGDirectDisplayID] { Array(panels.keys).sorted() }

    func retainDisplays(_ ids: Set<CGDirectDisplayID>) {
        for id in Array(panels.keys) where !ids.contains(id) || eligibleScreen(id) == nil {
            panels.removeValue(forKey: id)?.close()
        }
    }

    func configure(levels: [CGDirectDisplayID: Int]) {
        for id in Array(panels.keys) where levels[id] == nil || eligibleScreen(id) == nil {
            panels.removeValue(forKey: id)?.close()
        }
        for (id, percent) in levels { set(percent, for: id) }
    }

    private func eligibleScreen(_ id: CGDirectDisplayID) -> NSScreen? {
        guard CGDisplayIsBuiltin(id) == 0, CGDisplayIsOnline(id) != 0,
              CGDisplayIsActive(id) != 0, CGDisplayCopyDisplayMode(id) != nil else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
                && $0.frame.width > 0 && $0.frame.height > 0
        }
    }

    func set(_ percent: Int, for id: CGDirectDisplayID) {
        guard percent < 100, let screen = eligibleScreen(id) else {
            panels.removeValue(forKey: id)?.close()
            return
        }
        // Discovery may fire repeatedly while macOS rebuilds display spaces.
        // Do not allocate invisible full-display windows at 100% brightness or
        // replace an existing shade for every discovery notification.
        if panels[id] == nil {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Simple Mac Fixes Software Brightness"
            panel.backgroundColor = .black
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            // Cover application content while keeping menu controls and the HUD usable.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panels[id] = panel
        }
        if let panel = panels[id] {
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
            // Keep a visible floor so a held key cannot make the display black.
            panel.alphaValue = 0.9 * (1 - Double(Level.clamp(percent)) / 100)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func remove() {
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }
}
