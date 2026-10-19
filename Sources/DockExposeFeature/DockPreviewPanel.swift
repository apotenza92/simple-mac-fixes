import AppKit
import SwiftUI

/// What the panel shows: one app's windows, with pictures as they arrive.
@MainActor
final class DockPreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var windows: [DockWindow] = []
    @Published var pictures: [CGWindowID: CGImage] = [:]
    /// The window a click on the Dock icon brings forward: the most recent at first,
    /// then whichever card the pointer or a scroll on the icon last picked.
    @Published var selected: CGWindowID?
    /// Beside a side Dock the cards run top to bottom.
    @Published var isVertical = false
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
        // After isFloatingPanel, which resets the level. Above the Dock, and above our
        // copy of its name bubble, so its shadow falls on the copy as on the original.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    /// Glass in a window that isn't key turns frosted, even the clear kind, so the
    /// panel takes key while it shows. It never activates the app, so the window
    /// you were using keeps its look; only keys typed while it's open land here.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Places the panel clear of the Dock's own name bubble, on the side away from the
    /// screen edge the Dock sits on, and keeps it on screen.
    func show(beside icon: CGRect, edge: String, name: String) {
        let vertical = edge == "left" || edge == "right"
        if model.isVertical != vertical { model.isVertical = vertical }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(Self.appKitPoint(CGPoint(x: icon.midX, y: icon.midY))) })
            ?? NSScreen.main else { return }
        // Accessibility frames are top-left based; AppKit is bottom-left.
        let glassSize = CGSize(width: size.width - Self.margin * 2, height: size.height - Self.margin * 2)
        let origin = Self.origin(for: glassSize, beside: Self.appKitRect(icon), edge: edge,
                                 clearance: Self.nameBubbleClearance(for: name, edge: edge),
                                 within: screen.frame.insetBy(dx: 8, dy: 8))
        setFrame(CGRect(origin: origin, size: glassSize).insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
        orderFrontRegardless()
        makeKey()
    }

    /// Space between the icon and a bottom Dock's preview: the name bubble's gap to
    /// the icon, the bubble itself, then the same gap again, so both gaps match.
    static func nameBubbleClearance(for name: String, edge: String) -> CGFloat {
        DockNameBubble.gap * 2 + DockNameBubble.height
    }

    /// Above a bottom Dock's icon, centred on it and `clearance` away. Beside a side
    /// Dock, under the name bubble that sits beside the icon, lined up with the
    /// bubble's Dock-side end, or over the bubble when there's no room below. Kept
    /// inside `visible`; all in AppKit's bottom-left coordinates.
    static func origin(for size: CGSize, beside icon: CGRect, edge: String, clearance: CGFloat,
                       within visible: CGRect) -> CGPoint {
        let gap = DockNameBubble.gap, bubble = DockNameBubble.height
        var origin: CGPoint
        switch edge {
        case "left", "right":
            let x = edge == "left" ? icon.maxX + gap : icon.minX - gap - size.width
            let below = icon.midY - bubble / 2 - gap - size.height
            origin = CGPoint(x: x, y: below >= visible.minY ? below : icon.midY + bubble / 2 + gap)
        default: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + clearance)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private static func appKitRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func appKitPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }
}

struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel

    /// The Dock's own name bubble already names the app, so the preview doesn't.
    var body: some View {
        let layout = model.isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            ForEach(model.windows) { window in
                WindowCard(window: window, picture: model.pictures[window.id], appIcon: model.appIcon,
                           isSelected: model.selected == window.id,
                           select: { model.selected = window.id },
                           pointAt: { model.pointAt(window, $0) },
                           control: { model.control($0, window) }) {
                    model.choose(window)
                }
            }
        }
        .padding(10)
        .fixedSize()
        .modifier(PanelGlass(cornerRadius: DockPreviewPanel.cornerRadius))
        // The panel is key only so its glass stays clear; nothing in it takes keyboard focus.
        .focusEffectDisabled()
        .padding(DockPreviewPanel.margin)
    }
}

/// The system's regular glass, untouched; a material on systems without it.
private struct PanelGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct WindowCard: View {
    let window: DockWindow
    let picture: CGImage?
    let appIcon: NSImage?
    let isSelected: Bool
    let select: () -> Void
    let pointAt: (Bool) -> Void
    let control: (DockWindows.Control) -> Void
    let action: () -> Void
    @State private var hovering = false

    private static let pictureSize = CGSize(width: 200, height: 125)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ScrollingName(text: window.title.isEmpty ? "Window" : window.title, isScrolling: isSelected)
                    if let place = placeText {
                        Text(place)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .frame(width: Self.pictureSize.width)
                ZStack {
                    if let picture {
                        Image(decorative: picture, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .opacity(window.place == .here ? 1 : 0.6)
                    } else if let appIcon {
                        Image(nsImage: appIcon).resizable().frame(width: 48, height: 48).opacity(0.8)
                    }
                }
                .frame(width: Self.pictureSize.width, height: Self.pictureSize.height)
                .overlay(alignment: .topLeading) {
                    if hovering, DockWindows.hasControls(window) {
                        WindowControls(isMinimized: window.place == .minimized, perform: control)
                            .padding(6)
                            .transition(.opacity)
                    }
                }
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CardGlassStyle(isHighlighted: isSelected))
        .focusable(false)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) { hovering = isHovering }
            if isHovering { select() }
            pointAt(isHovering)
        }
    }

    private var placeText: String? {
        switch window.place {
        case .here: nil
        case .minimized: "Minimized"
        case .hidden: "Hidden"
        case let .otherDesktop(number, _): number.map { "Space \($0)" } ?? "Full Screen"
        }
    }
}

/// A card's state shows only through the system's own glass: none at rest, and a
/// second layer of regular glass on the panel's for the selected card.
private struct CardGlassStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHighlighted { CardGlass(isPressed: configuration.isPressed) }
            }
    }
}

private struct CardGlass: View {
    let isPressed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(isPressed ? .thinMaterial : .ultraThinMaterial)
        }
    }
}

/// Close, minimize and maximize, drawn like a window's own buttons: see-through
/// until the pointer reaches them, then solid with symbols.
private struct WindowControls: View {
    let isMinimized: Bool
    let perform: (DockWindows.Control) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            TrafficLight(style: .close, symbol: .close, label: "Close", isSolid: hovering) { perform(.close) }
            TrafficLight(style: .minimize, symbol: .minimize, label: "Minimize", isSolid: hovering) { perform(.minimize) }
                .disabled(isMinimized)
                .opacity(isMinimized ? 0.4 : 1)
            TrafficLight(style: .zoom, symbol: .zoom, label: "Maximize", isSolid: hovering) { perform(.maximize) }
        }
        .padding(2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct TrafficLight: View {
    /// Colours read from the system's own buttons: deeper at the top, lighter at
    /// the bottom, with a thin darker rim.
    enum Style {
        case close, minimize, zoom

        var top: Color {
            switch self {
            case .close: Color(red: 0.937, green: 0.514, blue: 0.439)
            case .minimize: Color(red: 0.953, green: 0.745, blue: 0.247)
            case .zoom: Color(red: 0.467, green: 0.769, blue: 0.196)
            }
        }

        var bottom: Color {
            switch self {
            case .close: Color(red: 0.914, green: 0.592, blue: 0.541)
            case .minimize: Color(red: 0.973, green: 0.835, blue: 0.325)
            case .zoom: Color(red: 0.655, green: 0.835, blue: 0.506)
            }
        }

        var rim: Color {
            switch self {
            case .close: Color(red: 0.831, green: 0.400, blue: 0.325)
            case .minimize: Color(red: 0.796, green: 0.584, blue: 0.125)
            case .zoom: Color(red: 0.404, green: 0.624, blue: 0.235)
            }
        }
    }

    /// Drawn rather than taken from a font, so each sits exactly in the middle.
    enum Symbol {
        case close, minimize, zoom

        var path: Path {
            Path { path in
                let c = TrafficLight.diameter / 2, r: CGFloat = 3
                switch self {
                case .close:
                    path.move(to: CGPoint(x: c - r, y: c - r)); path.addLine(to: CGPoint(x: c + r, y: c + r))
                    path.move(to: CGPoint(x: c + r, y: c - r)); path.addLine(to: CGPoint(x: c - r, y: c + r))
                case .minimize:
                    path.move(to: CGPoint(x: c - r - 0.5, y: c)); path.addLine(to: CGPoint(x: c + r + 0.5, y: c))
                case .zoom:
                    path.move(to: CGPoint(x: c - r - 0.5, y: c)); path.addLine(to: CGPoint(x: c + r + 0.5, y: c))
                    path.move(to: CGPoint(x: c, y: c - r - 0.5)); path.addLine(to: CGPoint(x: c, y: c + r + 0.5))
                }
            }
        }
    }

    let style: Style
    let symbol: Symbol
    let label: String
    let isSolid: Bool
    let action: () -> Void

    static let diameter: CGFloat = 14

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(LightStyle(style: style, symbol: symbol, isSolid: isSolid))
        .focusable(false)
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityLabel(label)
    }
}

/// One circle for both states, so a button never changes size: see-through with a
/// light sheen at rest, solid with its symbol under the pointer, and lit up
/// while pressed, as the window's own buttons are.
private struct LightStyle: ButtonStyle {
    let style: TrafficLight.Style
    let symbol: TrafficLight.Symbol
    let isSolid: Bool

    func makeBody(configuration: Configuration) -> some View {
        Circle()
            .fill(LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom))
            .opacity(isSolid ? 1 : 0.55)
            .overlay {
                Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                    .opacity(isSolid ? 0 : 1)
            }
            // Pressed, a button brightens past normal white where the screen allows,
            // the way the window's own buttons light up.
            .overlay {
                Circle().fill(Color(.sRGBLinear, white: 1, opacity: configuration.isPressed ? 0.45 : 0))
                    .blendMode(.plusLighter)
            }
            .overlay { Circle().strokeBorder(style.rim.opacity(isSolid ? 1 : 0.6), lineWidth: 0.5) }
            .overlay {
                symbol.path
                    .stroke(.black.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .opacity(isSolid ? 1 : 0)
            }
            .contentShape(Circle())
            .allowedDynamicRange(.high)
    }
}

/// A one-line name that ends in "…" when it doesn't fit, and while hovered
/// slides across to show the rest, pauses, then slides back, until the pointer leaves.
private struct ScrollingName: View {
    let text: String
    let isScrolling: Bool
    @State private var fullWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Points per second; slow enough to read.
    private static let speed: CGFloat = 40
    private static let pause: Duration = .milliseconds(900)

    private var overflow: CGFloat { max(0, fullWidth - visibleWidth) }

    var body: some View {
        let scrolling = isScrolling && overflow > 0
        // The truncated name sets the size; the whole name slides inside it and is cut
        // off at its edges, so a long name never reaches past its own card.
        label.lineLimit(1).truncationMode(.tail)
            .opacity(scrolling ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if scrolling { label.fixedSize().offset(x: offset) }
            }
            .clipped()
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
        .task(id: isScrolling) {
            offset = 0
            guard isScrolling else { return }
            while !Task.isCancelled, overflow > 0 {
                try? await Task.sleep(for: Self.pause)
                let distance = overflow
                let across = Double(distance / Self.speed)
                withAnimation(.linear(duration: across)) { offset = -distance }
                try? await Task.sleep(for: .seconds(across) + Self.pause)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.35)) { offset = 0 }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private var label: some View {
        Text(text).font(.callout)
    }
}


