import AppKit
import QuartzCore

/// A picture of a window shown at its real size and place, while its card in the
/// preview is pointed at. Clicks go straight through it.
@MainActor
final class WindowPeek: NSPanel {
    private let picture = CALayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Over ordinary windows, under the Dock and the preview.
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        // Gone in one frame when the real window takes over; a fade would blend the two.
        animationBehavior = .none
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        picture.contentsGravity = .resize
        view.layer?.addSublayer(picture)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `bounds` is in the top-left coordinates of mouse events. A dimmed peek is for a
    /// window that isn't really there right now, minimized or hidden, as its card shows.
    func show(_ image: CGImage, at bounds: CGRect, dimmed: Bool) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let frame = CGRect(x: bounds.minX, y: height - bounds.maxY, width: bounds.width, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        picture.opacity = dimmed ? 0.6 : 1
        picture.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
        if self.frame != frame { setFrame(frame, display: false) }
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
        invalidateShadow()
    }

    /// Swaps in a sharper picture of the window already showing.
    func update(_ image: CGImage) {
        guard isVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
        invalidateShadow()
    }

    func hidePeek() {
        guard isVisible else { return }
        orderOut(nil)
    }
}
