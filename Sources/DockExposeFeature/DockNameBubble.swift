import AppKit
import SwiftUI

/// Keeps the app's name up while the preview is open by showing a picture of the
/// Dock's own name bubble where the Dock drew it. The Dock removes its bubble as
/// soon as the pointer leaves the icon. With no picture, nothing is shown.
///
/// Measured from the macOS 27 Dock, for checking readings and spacing the preview:
/// 14-point text with 13.5 points of padding each side, 26 points tall, 9 points
/// from the icon, and a 7-point tip pointing at the icon.
@MainActor
final class DockNameBubble: NSPanel {
    static let height: CGFloat = 26
    static let gap: CGFloat = 9
    static let tipLength: CGFloat = 7.5
    static let font = NSFont.systemFont(ofSize: 14)

    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        // After isFloatingPanel, which resets the level. Above the Dock's own bubble and
        // the preview: the picture already has the preview's shadow across it, as the
        // Dock's bubble shows on screen, so it mustn't land on the copy a second time.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    static func width(for name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: font]).width) + 27
    }

    /// Shows a picture of the Dock's own bubble exactly where it was taken: the
    /// Dock's own pixels, so nothing differs. It is cut to the bubble's outline, so
    /// whatever is behind the bubble stays live around it.
    func show(snapshot: CGImage, at rect: CGRect, body: CGRect, edge: String) {
        // One picture pixel per screen pixel, never smoothed, so the copy is exact.
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 2
        var outline = body
        switch edge {
        case "left": outline.origin.x -= Self.tipLength; outline.size.width += Self.tipLength
        case "right": outline.size.width += Self.tipLength
        default: outline.size.height += Self.tipLength
        }
        let shape = BubbleShape(edge: edge, tipLength: Self.tipLength, bodyHeight: Self.height)
        host.rootView = AnyView(Image(decorative: snapshot, scale: scale)
            .interpolation(.none)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .mask(alignment: .topLeading) {
                // Past the outline far enough to keep the bubble's soft edge and its
                // faint shadow underneath; the picture there is the screen as it was.
                ZStack { shape.fill(); shape.stroke(lineWidth: 6) }
                    .frame(width: outline.width, height: outline.height)
                    .offset(x: outline.minX - rect.minX, y: outline.minY - rect.minY)
            })
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        setFrame(CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height), display: true)
        orderFrontRegardless()
    }
}

/// The Dock bubble's outline: a capsule with a short rounded tip pointing at the
/// icon. Cuts the picture of the Dock's bubble to shape.
struct BubbleShape: Shape {
    let edge: String
    let tipLength: CGFloat
    let bodyHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        // Draw for a bottom Dock (tip down), then rotate the result for side Docks.
        let vertical = edge == "left" || edge == "right"
        let canvas = vertical ? CGRect(x: 0, y: 0, width: rect.height, height: rect.width) : rect
        let body = CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: bodyHeight)
        // Plain circular ends, like the Dock's.
        var path = Path(roundedRect: body, cornerRadius: bodyHeight / 2, style: .circular)
        // Measured from the Dock: a concave join from 16 points either side, 45° sides
        // from a 16-point base, and a point rounded off about 7 points below the body.
        let mid = canvas.midX, base = body.maxY
        let apex = base + 8, corner: CGFloat = 1.5
        var tip = Path()
        tip.move(to: CGPoint(x: mid - 16, y: base - 1))
        tip.addQuadCurve(to: CGPoint(x: mid - 7.4, y: base + 0.6), control: CGPoint(x: mid - 8.6, y: base - 0.2))
        tip.addLine(to: CGPoint(x: mid - corner, y: apex - corner))
        tip.addQuadCurve(to: CGPoint(x: mid + corner, y: apex - corner), control: CGPoint(x: mid, y: apex))
        tip.addLine(to: CGPoint(x: mid + 7.4, y: base + 0.6))
        tip.addQuadCurve(to: CGPoint(x: mid + 16, y: base - 1), control: CGPoint(x: mid + 8.6, y: base - 0.2))
        tip.closeSubpath()
        // One outline, so the edge runs round the tip without a seam.
        path = path.union(tip)
        guard vertical else { return path }
        // Left Dock: tip points left. Right Dock: tip points right.
        let turn = edge == "left"
            ? CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
                .concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
            : CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        return path.applying(turn)
    }
}
