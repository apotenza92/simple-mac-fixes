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
        // After isFloatingPanel, which resets the level. Above the Dock's own bubble.
        level = .popUpMenu
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
                // Half a point past the outline keeps the bubble's soft edge.
                ZStack { shape.fill(); shape.stroke(lineWidth: 1) }
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

extension View {
    /// The Dock bubble's look: glass with a thin dark outline and a lighter top rim,
    /// both inside the edge so the shape is exactly its frame.
    @ViewBuilder
    func dockGlass<S: Shape>(in shape: S) -> some View {
        let rimmed = overlay {
            shape.stroke(
                LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                lineWidth: 2.5)
                .clipShape(shape)
        }
        .overlay { shape.stroke(.black.opacity(0.55), lineWidth: 1).clipShape(shape) }
        if #available(macOS 26.0, *) {
            rimmed.glassEffect(.regular, in: shape)
        } else {
            rimmed.background(.regularMaterial, in: shape)
        }
    }
}
