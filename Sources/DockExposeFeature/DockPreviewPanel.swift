import AppKit
import SwiftUI

/// What the panel shows: one app's windows, with pictures as they arrive.
@MainActor
final class DockPreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var windows: [DockWindow] = []
    @Published var pictures: [CGWindowID: CGImage] = [:]
    /// Live pictures of windows on this desktop, while the preview shows.
    @Published var live: [CGWindowID: LiveFeed] = [:]
    /// The window a click on the Dock icon brings forward: the most recent at first,
    /// then whichever card the pointer or a scroll on the icon last picked.
    @Published var selected: CGWindowID?
    /// Beside a side Dock the cards run top to bottom.
    @Published var isVertical = false
    /// Set when the cards are longer than the screen: they scroll, in this length.
    @Published var scrollLength: CGFloat?
    /// Counts previews opened, so each one's list starts scrolled to its first card.
    @Published var visit = 0
    /// The system's own animations, unless Reduce Motion or Instant Dock is on.
    @Published var animates = false
    var choose: (DockWindow) -> Void = { _ in }
    /// The pointer reaching (true) or leaving (false) a window's card.
    var pointAt: (DockWindow, Bool) -> Void = { _, _ in }
    var control: (DockWindows.Control, DockWindow) -> Void = { _, _ in }
}

/// A floating glass panel above the Dock that never takes focus from the app you're in.
@MainActor
final class DockPreviewPanel: NSPanel {
    let model = DockPreviewModel()
    private let host: NSHostingView<DockPreviewView>
    static let cornerRadius: CGFloat = 22
    /// Clear room around the glass inside the window. Glass draws its rim and a soft
    /// shadow past its shape, reaching about 23 points below it, and the window's
    /// square edge would cut them off.
    static let margin: CGFloat = 32

    /// The glass itself, without the clear room around it.
    var glassFrame: CGRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }

    init() {
        host = NSHostingView(rootView: DockPreviewView(model: model))
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        // After isFloatingPanel, which resets the level. Above the Dock.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // The preview opens and closes at once, like the Dock's own menus.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    /// Glass in a window that isn't key turns frosted, even the clear kind, so the
    /// panel takes key while it shows. It never activates the app, so the window
    /// you were using keeps its look; only keys typed while it's open land here.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The glass draws frosted in a window that is not key. Another app coming forward
    /// while the preview shows (a window chosen by scrolling on the icon) takes key from
    /// the panel, so the panel takes it back at once, before the frosted glass shows.
    /// Taking it back inside this call does not hold; on the next turn it does, and the
    /// frosted glass shows for 2 frames instead of 8.
    override func resignKey() {
        super.resignKey()
        guard isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.makeKey()
        }
    }

    /// Draws the panel once, off screen and see-through, so the first preview opens as
    /// fast as later ones.
    func prepare() {
        // Two sample cards, so the cards' views, the glass and becoming key are all done once.
        // Long names with punctuation, one of them selected, so text, its fallback fonts
        // and the sliding name are all set up too.
        model.windows = [
            DockWindow(id: 1, processIdentifier: 0, title: "Personal — A long window name & 4 Tabs, too long to fit…",
                       place: .here, bounds: .zero),
            DockWindow(id: 2, processIdentifier: 0, title: "Window", place: .minimized, bounds: .zero),
        ]
        model.selected = 1
        model.appIcon = NSApp.applicationIconImage
        if let context = CGContext(data: nil, width: 400, height: 250, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue),
           let picture = context.makeImage() {
            model.pictures = [1: picture, 2: picture]
        }
        host.layoutSubtreeIfNeeded()
        alphaValue = 0
        // On screen, though see-through: the window server makes an off-screen window key
        // without the work an on-screen one needs.
        let screen = NSScreen.main?.frame ?? .zero
        setFrame(CGRect(x: screen.midX - 300, y: screen.minY + 100, width: 600, height: 300), display: true)
        orderFrontRegardless()
        makeKey()
        display()
        orderOut(nil)
        alphaValue = 1
        model.windows = []
        model.selected = nil
        model.pictures = [:]
        model.appIcon = nil
    }

    /// Shows the panel over the Dock's name label for `icon`, on the side away from the
    /// screen edge the Dock sits on.
    func show(beside icon: CGRect, edge: String, magnified: Bool) {
        place(beside: icon, edge: edge, magnified: magnified)
        // The system's fade as it opens and closes, as for a utility panel, or none.
        animationBehavior = model.animates ? .utilityWindow : .none
        orderFrontRegardless()
        makeKey()
    }

    /// Moves the panel to where the Dock draws the name label for `icon` now. The label
    /// follows the icon as magnification grows and shrinks it, so the panel does too.
    func place(beside icon: CGRect, edge: String, magnified: Bool) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: icon.midX, y: primaryHeight - icon.midY))
        }) ?? NSScreen.main else { return }
        // Accessibility frames are top-left based; AppKit is bottom-left.
        var visible = screen.frame.insetBy(dx: 8, dy: 8)
        // Never over the menu bar. The visible frame leaves the Dock out too, but the
        // preview covers the Dock's name label, so only its top is used.
        visible.size.height = min(visible.maxY, screen.visibleFrame.maxY - 8) - visible.minY
        let visibleTopLeft = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
        let vertical = edge == "left" || edge == "right"
        fitToScreen(vertical: vertical, length: vertical ? visible.height : visible.width)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let glassSize = CGSize(width: size.width - Self.margin * 2, height: size.height - Self.margin * 2)
        let glass = Self.glassFrame(for: glassSize, beside: icon, edge: edge, magnified: magnified,
                                    scale: screen.backingScaleFactor, within: visibleTopLeft,
                                    firstCardCentre: firstCardCentre(glassLength: vertical ? glassSize.height : glassSize.width))
        let appKitGlass = CGRect(x: glass.minX, y: primaryHeight - glass.maxY, width: glass.width, height: glass.height)
        let target = appKitGlass.insetBy(dx: -Self.margin, dy: -Self.margin)
        guard target != frame else { return }
        setFrame(target, display: true)
    }

    private var fitted: (count: Int, vertical: Bool, length: CGFloat)?

    /// Lays the cards along the Dock's edge and, when they're longer than the screen,
    /// makes them scroll. Only when the count, the edge or the screen changes, so a
    /// scrolled list keeps its place while the preview follows the icon.
    private func fitToScreen(vertical: Bool, length: CGFloat) {
        let key = (count: model.windows.count, vertical: vertical, length: length)
        if let fitted, fitted == key { return }
        fitted = key
        if model.isVertical != vertical { model.isVertical = vertical }
        model.scrollLength = nil
        host.layoutSubtreeIfNeeded()
        let natural = host.fittingSize
        let along = (vertical ? natural.height : natural.width) - Self.margin * 2
        if along > length { model.scrollLength = length }
    }

    /// How far the first card's centre is from the glass's start along the cards, from
    /// the glass's length when not scrolling: every card is the same size.
    private func firstCardCentre(glassLength: CGFloat) -> CGFloat? {
        let count = CGFloat(model.windows.count)
        guard count > 0, model.scrollLength == nil else { return nil }
        let card = (glassLength - Self.padding * 2 - Self.spacing * (count - 1)) / count
        return Self.padding + card / 2
    }

    static let padding: CGFloat = 10
    static let spacing: CGFloat = 10

    /// A horizontal list scrolls with a plain mouse wheel too, as it does with Shift held.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, model.scrollLength != nil, !model.isVertical,
           event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
           let turned = event.cgEvent?.copy() {
            for (from, to) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventDeltaAxis2),
                               (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
                               (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)] {
                turned.setIntegerValueField(to, value: turned.getIntegerValueField(from))
                turned.setDoubleValueField(to, value: turned.getDoubleValueField(from))
                turned.setIntegerValueField(from, value: 0)
                turned.setDoubleValueField(from, value: 0)
            }
            if let sideways = NSEvent(cgEvent: turned) { return super.sendEvent(sideways) }
        }
        super.sendEvent(event)
    }

    /// Where the Dock's name label for `icon` starts, on the side of the label nearest
    /// the icon, its arrow included. Top-left coordinates, like `icon`.
    ///
    /// Measured from the macOS 27 Dock on every edge, at icon sizes 16 to 80 and with
    /// magnification off and from 36 to 128. The label sits at a fixed distance from
    /// the icon's accessibility frame, also while magnification is growing the icon;
    /// that distance changes only when magnification is switched on or off. The Dock
    /// puts the label on the screen's pixel grid; this rounds toward the icon, so the
    /// preview always covers the whole label.
    static func labelEdge(beside icon: CGRect, edge: String, magnified: Bool, scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        switch edge {
        case "left":
            return floor((icon.maxX + (magnified ? 0.5 : 5.5)) * scale) / scale
        case "right":
            return ceil((icon.minX + (magnified ? 1.5 : -3.5)) * scale) / scale
        default:
            // The arrow's tip. A bottom Dock's frame is taller than the icon by 12 points,
            // or by 16 from icon size 48; magnified, the tip sits a quarter of that, plus
            // 4 points, inside the frame.
            let extra = icon.height - icon.width
            return ceil((icon.minY + (magnified ? 4 + extra / 4 : -2)) * scale) / scale
        }
    }

    /// The glass, with its edge nearest the Dock on the label's start, so it covers the
    /// label exactly. Above a bottom Dock it's centred on the icon; beside a side Dock
    /// the first card is, at `firstCardCentre` from the glass's top (the glass's middle
    /// when nil). Kept inside `visible`; top-left coordinates.
    static func glassFrame(for size: CGSize, beside icon: CGRect, edge: String, magnified: Bool, scale: CGFloat,
                           within visible: CGRect, firstCardCentre: CGFloat? = nil) -> CGRect {
        let start = labelEdge(beside: icon, edge: edge, magnified: magnified, scale: scale)
        let top = icon.midY - (firstCardCentre ?? size.height / 2)
        var origin: CGPoint
        switch edge {
        case "left": origin = CGPoint(x: start, y: top)
        case "right": origin = CGPoint(x: start - size.width, y: top)
        default: origin = CGPoint(x: icon.midX - size.width / 2, y: start - size.height)
        }
        // Whole pixels across the Dock too, so the glass's edges stay sharp.
        let scale = max(scale, 1)
        switch edge {
        case "left", "right": origin.y = (origin.y * scale).rounded() / scale
        default: origin.x = (origin.x * scale).rounded() / scale
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel

    private var cards: some View {
        let layout = model.isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DockPreviewPanel.spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DockPreviewPanel.spacing))
        return layout {
            ForEach(model.windows) { window in
                WindowCard(window: window, picture: model.pictures[window.id], live: model.live[window.id],
                           appIcon: model.appIcon, animates: model.animates,
                           isSelected: model.selected == window.id,
                           select: { model.selected = window.id },
                           pointAt: { model.pointAt(window, $0) },
                           control: { model.control($0, window) }) {
                    model.choose(window)
                }
                .id(window.id)
            }
        }
    }

    /// The cards run along the Dock's edge: in a row above a bottom Dock, in a column
    /// beside a side Dock. When they're longer than the screen they scroll.
    var body: some View {
        Group {
            if let length = model.scrollLength {
                ScrollViewReader { proxy in
                    ScrollView(model.isVertical ? .vertical : .horizontal) {
                        cards.padding(DockPreviewPanel.padding)
                    }
                    // No scroll bar: the panel keeps its plain glass look, and the cards past
                    // its end show that there is more.
                    .scrollIndicators(.never)
                    .id(model.visit)
                    .frame(width: model.isVertical ? nil : length, height: model.isVertical ? length : nil)
                    .fixedSize(horizontal: model.isVertical, vertical: !model.isVertical)
                    // Cards scrolling past the rounded corners stay inside the glass.
                    .clipShape(RoundedRectangle(cornerRadius: DockPreviewPanel.cornerRadius, style: .continuous))
                    // A card picked by scrolling on the Dock icon comes into view.
                    .onChange(of: model.selected) { _, selected in
                        guard let selected else { return }
                        withAnimation(model.animates ? .default : nil) { proxy.scrollTo(selected) }
                    }
                }
            } else {
                cards.padding(DockPreviewPanel.padding).fixedSize()
            }
        }
        .modifier(PanelGlass(cornerRadius: DockPreviewPanel.cornerRadius))
        // The panel is key only so its glass stays clear; nothing in it takes keyboard focus.
        .focusEffectDisabled()
        .padding(DockPreviewPanel.margin)
    }
}

/// The Dock's own glass behind the cards, so the preview reads as part of the Dock; the
/// system's regular glass where that isn't available, and a material before glass.
private struct PanelGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            if DockGlass.isAvailable {
                content.background { veil(shape) }.background(DockGlass(cornerRadius: cornerRadius))
            } else {
                content.background { veil(shape) }.glassEffect(.regular, in: shape)
            }
        } else {
            content.background { veil(shape) }.background(.ultraThinMaterial, in: shape)
        }
    }

    /// The Dock's glass, made calmer so that every name meets the WCAG AA contrast of
    /// 4.5 : 1 on any desktop: a white veil in light mode and a black one in dark mode.
    /// Measured over seven solid colours behind the preview, the worst cases were a black
    /// desktop in light mode (5.0 : 1) and a white one in dark mode (5.0 : 1 selected,
    /// 5.7 : 1 for the others). The glass is already solid with Reduce Transparency, so it
    /// gets none.
    @ViewBuilder
    private func veil(_ shape: RoundedRectangle) -> some View {
        if !reduceTransparency {
            shape.fill(colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.44))
        }
    }
}

/// The glass the Dock bar is made of. AppKit's glass view has private variants for the
/// system's own surfaces; variant 3 matched the Dock bar exactly, measured over solid
/// colours (every channel the same value) and over a pattern (the same blur).
@available(macOS 26.0, *)
private struct DockGlass: NSViewRepresentable {
    static let dockVariant = 3
    static let isAvailable = NSGlassEffectView.instancesRespond(to: NSSelectorFromString("set_variant:"))

    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.setValue(Self.dockVariant, forKey: "_variant")
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

struct WindowCard: View {
    let window: DockWindow
    let picture: CGImage?
    /// The window's live picture once its first frame came, which replaces the still one.
    let live: LiveFeed?
    let appIcon: NSImage?
    /// The system's own animations, unless Reduce Motion or Instant Dock is on.
    let animates: Bool
    let isSelected: Bool
    let select: () -> Void
    let pointAt: (Bool) -> Void
    let control: (DockWindows.Control) -> Void
    let action: () -> Void
    /// The size of Safari's preview of a tab, measured on screen.
    static let size = CGSize(width: 280, height: 218)
    /// One inset for everything, the same as the panel's padding and the space between
    /// cards: the buttons are this far from the card's top and left edges, the name from
    /// its right edge, and the picture from its sides, its bottom and the row above it.
    static let padding = DockPreviewPanel.padding
    /// Concentric with the panel's corners.
    static let cornerRadius = DockPreviewPanel.cornerRadius - padding
    /// As tall as the buttons; the name is centred on them.
    private static let rowHeight = WindowButtonGroup.size.height
    private static let inner = CGSize(width: size.width - 2 * padding, height: size.height - 2 * padding)
    static let pictureSize = CGSize(width: inner.width, height: inner.height - rowHeight - padding)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Self.padding) {
                // The name starts 12 points after the green button.
                HStack(spacing: 12) {
                    // Always in the same spot: the window's own buttons, in colour on the
                    // selected card and in the system's grey on the others.
                    if DockWindows.hasControls(window) {
                        WindowButtons(isActive: isSelected, isMinimized: window.place == .minimized, perform: control)
                            .frame(width: WindowButtonGroup.size.width, height: WindowButtonGroup.size.height)
                    }
                    ScrollingName(text: window.title.isEmpty ? "Window" : window.title, isScrolling: isSelected,
                                  animates: animates)
                        .modifier(DockLabel())
                }
                .frame(width: Self.inner.width, height: Self.rowHeight)
                // At the top, so the gap under the name row is always the same.
                ZStack(alignment: .top) {
                    if let live {
                        LivePicture(feed: live).aspectRatio(live.aspectRatio, contentMode: .fit)
                    } else if let picture {
                        Image(decorative: picture, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // No clip: the capture has the window's own corners, and a
                            // fixed radius cut them off at this scale.
                            .opacity(window.place == .here ? 1 : 0.6)
                    } else if let appIcon {
                        Image(nsImage: appIcon).resizable().frame(width: 48, height: 48).opacity(0.8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // The picture replaces the app's icon with the system's fade, or at once.
                .animation(animates ? .default : nil, value: picture != nil)
                .transaction { transaction in
                    if !animates {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .frame(width: Self.pictureSize.width, height: Self.pictureSize.height, alignment: .top)
            }
            .padding(Self.padding)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(CardGlassStyle(isHighlighted: isSelected, animates: animates))
        .focusable(false)
        .onHover { isHovering in
            if isHovering { select() }
            pointAt(isHovering)
        }
    }
}

/// A card's state shows only through the system's own glass: none at rest, and a
/// second layer of regular glass on the panel's for the selected card.
private struct CardGlassStyle: ButtonStyle {
    let isHighlighted: Bool
    let animates: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                // The glass comes and goes with the system's fade, or at once. Only the glass:
                // a fade on the whole card also faded the sliding name out where it stood,
                // over the name that replaces it.
                ZStack {
                    if isHighlighted { CardGlass(isPressed: configuration.isPressed) }
                }
                .animation(animates ? .default : nil, value: isHighlighted)
            }
    }
}

/// The selected card: the whole card in the glass of the Dock's name label.
private struct CardGlass: View {
    let isPressed: Bool

    var body: some View {
        Color.clear.modifier(DockLabelGlass(shape: RoundedRectangle(cornerRadius: WindowCard.cornerRadius, style: .continuous)))
    }
}

/// The window's own close, minimize and maximize buttons: AppKit's real ones, so they
/// look and act exactly like a window's, symbols on hover included.
private struct WindowButtons: NSViewRepresentable {
    let isActive: Bool
    let isMinimized: Bool
    let perform: (DockWindows.Control) -> Void

    func makeNSView(context: Context) -> WindowButtonGroup { WindowButtonGroup() }

    func updateNSView(_ group: WindowButtonGroup, context: Context) {
        group.perform = perform
        group.update(isActive: isActive, isMinimized: isMinimized)
    }
}

/// Holds the three buttons as a window's title bar does. A window's buttons show their
/// symbols while the pointer is over any of them: each asks its superview
/// `_mouseInGroup:`, and is told to look again with `mouseEnteredOrExited`. A disabled
/// button draws in the grey of a window in the background, so the other cards use that.
final class WindowButtonGroup: NSView {
    /// Three 14-point buttons 9 points apart, as in a window's title bar.
    static let size = CGSize(width: 14 * 3 + 9 * 2, height: 14)
    private static let controls: [(NSWindow.ButtonType, DockWindows.Control)] = [
        (.closeButton, .close), (.miniaturizeButton, .minimize), (.zoomButton, .maximize),
    ]
    private static let lookAgain = NSSelectorFromString("mouseEnteredOrExited")

    var perform: (DockWindows.Control) -> Void = { _ in }
    private var buttons: [NSButton] = []
    private var pointerInside = false

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        for (index, (type, _)) in Self.controls.enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable])
            else { continue }
            button.setFrameOrigin(CGPoint(x: CGFloat(index) * 23, y: 0))
            button.tag = index
            button.target = self
            button.action = #selector(pressed(_:))
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.size }

    func update(isActive: Bool, isMinimized: Bool) {
        var changed = false
        for button in buttons {
            let enabled = isActive && !(Self.controls[button.tag].1 == .minimize && isMinimized)
            if button.isEnabled != enabled { button.isEnabled = enabled; changed = true }
        }
        if changed { lookAgain() }
    }

    @objc private func pressed(_ sender: NSButton) {
        perform(Self.controls[sender.tag].1)
    }

    @objc func _mouseInGroup(_ button: NSButton) -> Bool { pointerInside }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; lookAgain() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; lookAgain() }

    private func lookAgain() {
        for button in buttons where button.responds(to: Self.lookAgain) { button.perform(Self.lookAgain) }
    }
}

/// A one-line name that ends in "…" when it doesn't fit, and while hovered
/// slides across to show the rest, pauses, then slides back, until the pointer leaves.
/// The glass of the Dock's own name label, in any shape.
///
/// The Dock's label sits on the desktop; this sits on the preview's Dock glass. Clear
/// glass with a light tint in light mode comes out like the Dock's label: measured over
/// solid colours behind both, within 5 levels on average. In dark mode the tint is black
/// 0.16, darker than the Dock's label (0.06 matched it), so that the selected name keeps
/// 4.5 : 1 on a white desktop while the card stays lighter than the others.
///
/// With Reduce Transparency on, the Dock draws its label almost solid, and plain regular
/// glass, which goes solid the same way, matches it within 2 levels.
private struct DockLabelGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let tint = colorScheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.32)
            content.glassEffect(reduceTransparency ? .regular : .clear.tint(tint), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A window's name with the Dock name label's text: 14-point system text in the standard
/// label colour, at the left of the title row, just after the window's buttons, and as far in
/// from the end as the buttons are from the start. The selected card is in the label's
/// glass as a whole; on the other cards the name sits on the Dock glass alone. The room
/// is the same either way, so nothing moves as the selection changes.
private struct DockLabel: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScrollingName: View {
    let text: String
    let isScrolling: Bool
    /// Without animations the name moves to its end and back in single steps.
    let animates: Bool
    @State private var fullWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// Whether the name fades out at each edge: at an edge where more of it is past the edge.
    @State private var fadesLeading = false
    @State private var fadesTrailing = true
    /// Slides under way: the whole name shows, in place of the one that ends in "…".
    @State private var sliding = false
    @State private var slides: Task<Void, Never>?
    /// Counts selections and deselections, so a slide back that ends late changes nothing.
    @State private var turn = 0

    /// Points per second; slow enough to read.
    private static let speed: CGFloat = 40
    private static let pause: Duration = .milliseconds(500)
    /// The name fades out over this width at an edge, instead of a hard cut.
    private static let fadeWidth: CGFloat = 14
    private static let fadeTime: TimeInterval = 0.2

    private var overflow: CGFloat { max(0, fullWidth - visibleWidth) }

    var body: some View {
        let scrolling = sliding && overflow > 0
        // The truncated name sets the size; the whole name slides inside it and fades out
        // at its edges, so a long name never reaches past its own card.
        label.lineLimit(1).truncationMode(.tail)
            .opacity(scrolling ? 0 : 1)
            .frame(alignment: .leading)
            .overlay(alignment: .leading) {
                if scrolling { label.fixedSize().offset(x: offset) }
            }
            .mask {
                if scrolling { fadeMask } else { Rectangle() }
            }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { visibleWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in visibleWidth = width }
        })
        // Measures the whole name without affecting layout.
        .background(alignment: .leading) {
            label.fixedSize().hidden().background(GeometryReader { proxy in
                Color.clear
                    .onAppear { fullWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in fullWidth = width }
            })
        }
        // Deselected halfway, the name slides straight back to its start, as fast as it
        // does at the end of a slide. Stopping it where it stood made it jump.
        .onChange(of: isScrolling, initial: true) { _, isScrolling in
            turn += 1
            slides?.cancel()
            slides = nil
            if isScrolling {
                slides = Task { await slide() }
            } else {
                slideBack()
            }
        }
        .onDisappear {
            slides?.cancel()
            slides = nil
        }
    }

    private static let backTime: TimeInterval = 0.25

    private func slide() async {
        while !Task.isCancelled, overflow > 0 {
            sliding = true
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            let distance = overflow
            let across = Double(distance / Self.speed)
            let fade: Animation? = animates ? .easeInOut(duration: Self.fadeTime) : nil
            if animates {
                withAnimation(.linear(duration: across)) { offset = -distance }
                withAnimation(fade) { fadesLeading = true }
                // The end of the name comes in: no fade at the trailing edge once it is there.
                try? await Task.sleep(for: .seconds(max(0, across - Self.fadeTime)))
                guard !Task.isCancelled else { return }
                withAnimation(fade) { fadesTrailing = false }
                try? await Task.sleep(for: .seconds(Self.fadeTime))
            } else {
                // Held at the start as long as the slide takes, then at the end.
                try? await Task.sleep(for: .seconds(across))
                guard !Task.isCancelled else { return }
                withAnimation(nil) {
                    offset = -distance
                    fadesLeading = true
                    fadesTrailing = false
                }
            }
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            withAnimation(animates ? .easeInOut(duration: Self.backTime) : nil) {
                offset = 0
                fadesLeading = false
                fadesTrailing = true
            }
            try? await Task.sleep(for: .seconds(Self.backTime))
        }
        if !Task.isCancelled { sliding = false }
    }

    /// Back to the start of the name, then the name that ends in "…".
    private func slideBack() {
        guard sliding else { return }
        guard animates, offset != 0 else {
            offset = 0
            fadesLeading = false
            fadesTrailing = true
            sliding = false
            return
        }
        withAnimation(.easeInOut(duration: Self.backTime)) {
            offset = 0
            fadesLeading = false
            fadesTrailing = true
        }
        let turn = turn
        Task {
            try? await Task.sleep(for: .seconds(Self.backTime))
            if self.turn == turn { sliding = false }
        }
    }

    /// Opaque in the middle, fading to clear at an edge where more of the name is past it.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            edge(fading: fadesLeading, towards: .leading)
            Rectangle()
            edge(fading: fadesTrailing, towards: .trailing)
        }
    }

    private func edge(fading: Bool, towards side: UnitPoint) -> some View {
        ZStack {
            LinearGradient(colors: [.clear, .black], startPoint: side, endPoint: side == .leading ? .trailing : .leading)
            Rectangle().opacity(fading ? 0 : 1)
        }
        .frame(width: Self.fadeWidth)
    }

    /// The Dock's own name label: the 14-point system font, regular, in the standard label
    /// colour, measured from the Dock on screen. The same on every card, selected or not.
    private var label: some View {
        Text(text).font(.system(size: 14))
    }
}


