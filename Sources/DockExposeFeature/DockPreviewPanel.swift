import AppKit
import SwiftUI

/// What the panel shows: one app's windows, with pictures as they arrive.
@MainActor
final class DockPreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var windows: [DockWindow] = []
    @Published var pictures: [CGWindowID: CGImage] = [:]
    var choose: (DockWindow) -> Void = { _ in }
    var control: (DockWindows.Control, DockWindow) -> Void = { _, _ in }
}

/// A floating glass panel above the Dock that never takes focus from the app you're in.
@MainActor
final class DockPreviewPanel: NSPanel {
    let model = DockPreviewModel()

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        // After isFloatingPanel, which resets the level. Above the Dock, so the
        // preview covers the Dock's own name bubble for the icon.
        level = .popUpMenu
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: DockPreviewView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the panel beside the icon, on the side away from the screen edge
    /// the Dock sits on, clear of the Dock's own name bubble, and keeps it on screen.
    func show(beside icon: CGRect, edge: String, name: String) {
        guard let host = contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(Self.appKitPoint(CGPoint(x: icon.midX, y: icon.midY))) })
            ?? NSScreen.main else { return }
        // Accessibility frames are top-left based; AppKit is bottom-left.
        let origin = Self.origin(for: size, beside: Self.appKitRect(icon), edge: edge,
                                 clearance: Self.nameBubbleClearance(for: name, edge: edge),
                                 within: screen.frame.insetBy(dx: 8, dy: 8))
        setFrame(CGRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }

    /// Space between the icon and the preview: the name bubble's gap to the icon,
    /// the bubble itself, then the same gap again, so both gaps match.
    static func nameBubbleClearance(for name: String, edge: String) -> CGFloat {
        let bubble = edge == "left" || edge == "right" ? DockNameBubble.width(for: name) : DockNameBubble.height
        return DockNameBubble.gap * 2 + bubble
    }

    /// Centred on the icon, `clearance` away on the side away from the Dock's edge,
    /// kept inside `visible`. All in AppKit's bottom-left coordinates.
    static func origin(for size: CGSize, beside icon: CGRect, edge: String, clearance: CGFloat,
                       within visible: CGRect) -> CGPoint {
        var origin: CGPoint
        switch edge {
        case "left": origin = CGPoint(x: icon.maxX + clearance, y: icon.midY - size.height / 2)
        case "right": origin = CGPoint(x: icon.minX - clearance - size.width, y: icon.midY - size.height / 2)
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
        HStack(alignment: .top, spacing: 10) {
            ForEach(model.windows) { window in
                WindowCard(window: window, picture: model.pictures[window.id], appIcon: model.appIcon,
                           control: { model.control($0, window) }) {
                    model.choose(window)
                }
            }
        }
        .padding(10)
        .fixedSize()
        .dockGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct WindowCard: View {
    let window: DockWindow
    let picture: CGImage?
    let appIcon: NSImage?
    let control: (DockWindows.Control) -> Void
    let action: () -> Void
    @State private var hovering = false

    private static let pictureSize = CGSize(width: 200, height: 125)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ScrollingName(text: window.title.isEmpty ? "Window" : window.title, isScrolling: hovering)
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
        .buttonStyle(CardGlassStyle(isHovered: hovering))
        .onHover { isHovering in withAnimation(.easeOut(duration: 0.12)) { hovering = isHovering } }
        .help(window.title)
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

/// Liquid Glass shows a card's state: the panel's own glass at rest, a lighter
/// glass card under the pointer, and lighter again while it is being clicked.
private struct CardGlassStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lift: Double = configuration.isPressed ? 2 : isHovered ? 1 : 0
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .background {
                if lift > 0 { CardGlass(lift: lift, shape: shape) }
            }
            .animation(.easeOut(duration: 0.12), value: lift)
    }
}

private struct CardGlass<S: Shape>: View {
    let lift: Double
    let shape: S

    var body: some View {
        if #available(macOS 26.0, *) {
            // The glass card itself lifts a hovered card; a light tint lifts it again while clicked.
            Color.clear.glassEffect(.regular.tint(.white.opacity(lift > 1 ? 0.2 : 0)), in: shape)
        } else {
            shape.fill(.white.opacity(0.08 * lift))
        }
    }
}

/// Close, minimize and maximize, drawn like a window's own buttons.
private struct WindowControls: View {
    let isMinimized: Bool
    let perform: (DockWindows.Control) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            light(.red, symbol: "xmark", label: "Close") { perform(.close) }
            light(.yellow, symbol: "minus", label: "Minimize") { perform(.minimize) }
                .disabled(isMinimized)
                .opacity(isMinimized ? 0.4 : 1)
            light(.green, symbol: "plus", label: "Maximize") { perform(.maximize) }
        }
        .padding(2)
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                // Keeps the dots clear on light and dark window pictures alike.
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55))
                        .opacity(hovering ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
        ZStack(alignment: .leading) {
            if isScrolling, overflow > 0 {
                label.fixedSize().offset(x: offset)
            } else {
                label.lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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


