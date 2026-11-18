import AppKit
import QuartzCore

/// A picture of a window shown at its real size and place, while its card in the
/// preview is pointed at. Clicks go straight through it.
@MainActor
final class WindowPeek: NSPanel {
    /// The system's own fades, unless Reduce Motion or Instant Dock is on.
    var animates = false
    /// Counts shows and hides, so a fade that ends after the peek came back leaves it up.
    private var fades = 0
    private let picture = CALayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Over ordinary windows, under the Dock and the preview.
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        // Fades are its own: gone in one frame when the real window takes over, where a fade
        // would blend the two.
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
        fades += 1
        if !isVisible || alphaValue < 1 {
            if !isVisible { alphaValue = animates ? 0 : 1 }
            orderFrontRegardless()
            if animates {
                NSAnimationContext.runAnimationGroup { _ in animator().alphaValue = 1 }
            } else {
                alphaValue = 1
            }
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

    /// A live frame of the window already showing. The shadow follows the window's
    /// shape, which a new frame of the same window does not change, so it stays.
    func updateLive(_ image: CGImage) {
        guard isVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }

    /// Goes with the system's fade when `animated`, else at once.
    func hidePeek(animated: Bool = false) {
        guard isVisible else { return }
        fades += 1
        guard animated, animates else {
            orderOut(nil)
            alphaValue = 1
            return
        }
        let fade = fades
        NSAnimationContext.runAnimationGroup { _ in
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again while it faded: it stays.
                guard let self, self.fades == fade else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        }
    }
}
