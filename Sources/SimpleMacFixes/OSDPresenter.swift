import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class OSDPresenter {
    enum Kind: String {
        case volume
        case muted
        case brightness

        var leadingSymbol: String {
            switch self {
            case .brightness: return "sun.min.fill"
            case .volume, .muted: return "speaker.fill"
            }
        }

        var trailingSymbol: String {
            switch self {
            case .brightness: return "sun.max.fill"
            case .volume, .muted: return "speaker.wave.3.fill"
            }
        }

        /// The single icon of the macOS 27.2 overlay; the speaker shows the level like
        /// the system's does.
        func symbol(percent: Double) -> String {
            switch self {
            case .brightness: return "sun.max.fill"
            case .muted: return "speaker.slash.fill"
            case .volume:
                switch percent {
                case ...0: return "speaker.fill"
                case ..<(100.0 / 3): return "speaker.wave.1.fill"
                case ..<(200.0 / 3): return "speaker.wave.2.fill"
                default: return "speaker.wave.3.fill"
                }
            }
        }

        var menuBarItem: MenuBarItemLocator.Item {
            self == .brightness ? .display : .sound
        }
    }

    /// macOS 27.2 replaced the named overlay in the top right corner with a segmented
    /// capsule under the Sound or Display menu bar icon.
    enum Style {
        case named
        case segmented

        static var current: Style {
            if #available(macOS 27.2, *) { return .segmented }
            return .named
        }

        var size: NSSize {
            switch self {
            case .named: return NSSize(width: 292, height: 64)
            case .segmented: return NSSize(width: 308, height: 64)
            }
        }
    }

    struct Content: Equatable {
        let kind: Kind
        let name: String
        let percent: Double
    }

    final class Model: ObservableObject {
        @Published var content: Content
        init(_ content: Content) { self.content = content }
    }

    private var models: [CGDirectDisplayID: Model] = [:]
    private var deadlines: [CGDirectDisplayID: TimeInterval] = [:]
    private var dismissalTimer: Timer?
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var revisions: [CGDirectDisplayID: Int] = [:]
    private let diagnostics = UserDefaults.standard
    private var pendingDiagnostics: DispatchWorkItem?
    private var latestDiagnostics: (content: Content, displayID: CGDirectDisplayID)?
    private lazy var hudCount = diagnostics.integer(forKey: "runtimeHUDCount")
    private let style = Style.current
    private let menuBarItems = MenuBarItemLocator()

    init() {
        if style == .segmented { menuBarItems.refresh() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: style.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.title = "\(AppIdentity.name) HUD"
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }

    func show(kind: Kind, name: String, percent: Double, displayID: CGDirectDisplayID? = nil) {
        let targetID = displayID ?? CGMainDisplayID()
        showSwiftUI(kind: kind, name: name, percent: min(max(percent, 0), 100), displayID: targetID)
    }

    private func showSwiftUI(kind: Kind, name: String, percent: Double, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        for id in Array(panels.keys) where !NSScreen.screens.contains(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) {
            deadlines.removeValue(forKey: id)
            models.removeValue(forKey: id)
            panels.removeValue(forKey: id)?.close()
            revisions.removeValue(forKey: id)
        }
        revisions[displayID] = (revisions[displayID] ?? 0) + 1
        let content = Content(kind: kind, name: name, percent: percent)
        let panel: NSPanel
        if let existing = panels[displayID], let model = models[displayID] {
            panel = existing
            if model.content != content { model.content = content }
        } else {
            panel = makePanel()
            let model = Model(content)
            models[displayID] = model
            if #available(macOS 26.0, *), style == .segmented {
                panel.contentView = NSHostingView(rootView: SegmentedOSDView(model: model))
            } else {
                panel.contentView = NSHostingView(rootView: OSDView(model: model))
            }
            panels[displayID] = panel
        }

        let origin = self.origin(for: panel.frame.size, kind: kind, on: screen)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if panel.alphaValue != 1 { panel.alphaValue = 1 }
        if !panel.isVisible { panel.orderFrontRegardless() }
        hudCount += 1
        latestDiagnostics = (content, displayID)
        scheduleDiagnostics()

        deadlines[displayID] = ProcessInfo.processInfo.systemUptime + 1.15
        if dismissalTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissExpiredPanels() }
            }
            dismissalTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func origin(for size: NSSize, kind: Kind, on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let menuBarHeight = max(0, frame.maxY - screen.visibleFrame.maxY)
        switch style {
        case .named:
            return NSPoint(x: frame.maxX - size.width - 16,
                           y: frame.maxY - menuBarHeight - size.height - 8)
        case .segmented:
            // Measured from the system's overlay: centred under the menu bar icon,
            // 10 points below the menu bar.
            menuBarItems.refresh()
            let centre = menuBarItems.offsetFromRightEdge(for: kind.menuBarItem).map { frame.maxX - $0 }
                ?? frame.maxX - 16 - size.width / 2
            let x = min(max(centre - size.width / 2, frame.minX + 8), frame.maxX - 8 - size.width)
            let barHeight = max(menuBarHeight, NSStatusBar.system.thickness)
            return NSPoint(x: x.rounded(), y: frame.maxY - barHeight - 10 - size.height)
        }
    }

    private func scheduleDiagnostics() {
        guard pendingDiagnostics == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDiagnostics = nil
            guard let latest = self.latestDiagnostics else { return }
            self.diagnostics.set(latest.content.kind.rawValue, forKey: "runtimeHUDKind")
            self.diagnostics.set(latest.content.name, forKey: "runtimeHUDName")
            self.diagnostics.set(latest.content.percent, forKey: "runtimeHUDPercent")
            self.diagnostics.set(latest.displayID, forKey: "runtimeHUDDisplayID")
            self.diagnostics.set(self.panels.values.contains { $0.isVisible }, forKey: "runtimeHUDVisible")
            self.diagnostics.set(self.hudCount, forKey: "runtimeHUDCount")
        }
        pendingDiagnostics = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func dismissExpiredPanels() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, deadline) in deadlines where deadline <= now {
            deadlines.removeValue(forKey: id)
            guard let panel = panels[id] else { continue }
            let revision = revisions[id]
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.revisions[id] == revision else { return }
                    panel.orderOut(nil)
                    self.diagnostics.set(self.panels.values.contains { $0.isVisible }, forKey: "runtimeHUDVisible")
                }
            }
        }
        if deadlines.isEmpty { dismissalTimer?.invalidate(); dismissalTimer = nil }
    }

}

private struct OSDView: View {
    @ObservedObject private var appearance = ControlAppearance.shared
    @ObservedObject var model: OSDPresenter.Model
    private var kind: OSDPresenter.Kind { model.content.kind }
    private var name: String { model.content.name }
    private var percent: Double { model.content.percent }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            OSDLevel(kind: kind, percent: percent)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(width: 292, height: 64, alignment: .topLeading)
        .hudGlass()
        .environment(\.colorScheme, appearance.colorScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(Int(percent.rounded())) percent")
    }
}

private struct OSDLevel: View {
    let kind: OSDPresenter.Kind
    let percent: Double

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: kind.leadingSymbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12)
            VStack(spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule()
                            .fill(.white.opacity(0.88))
                            .frame(width: geometry.size.width * displayedFraction)
                    }
                }
                .frame(height: 4)
                HStack(spacing: 0) {
                    ForEach(0..<16, id: \.self) { index in
                        Circle().fill(.white.opacity(0.24)).frame(width: 2, height: 2)
                        if index != 15 { Spacer() }
                    }
                }
                .frame(height: 2)
            }
            Image(systemName: kind.trailingSymbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14)
        }
        .frame(height: 13)
        .foregroundStyle(.white.opacity(0.92))
    }

    private var displayedFraction: CGFloat {
        kind == .muted ? 0 : percent / 100
    }
}

/// The macOS 27.2 overlay: one icon, then 16 segments that fill one step per key press.
/// Sizes are measured from the system's own overlay.
@available(macOS 26.0, *)
private struct SegmentedOSDView: View {
    @ObservedObject private var appearance = ControlAppearance.shared
    @ObservedObject var model: OSDPresenter.Model
    private var content: OSDPresenter.Content { model.content }

    var body: some View {
        HStack(spacing: 12.5) {
            Image(systemName: content.kind.symbol(percent: content.percent))
                .font(.system(size: 21, weight: .medium))
                .frame(width: 28, alignment: .leading)
            OSDSegments(fraction: content.kind == .muted ? 0 : content.percent / 100,
                        emptyOpacity: appearance.colorScheme == .dark ? 0.18 : 0.5)
                .frame(width: 214, height: 4)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.leading, 22)
        .frame(width: 308, height: 64)
        // The system overlay is a shade darker than plain glass, which keeps the empty
        // segments visible over white windows.
        .background(Capsule().fill(.black.opacity(0.14)))
        .glassEffect(.regular, in: Capsule())
        .environment(\.colorScheme, appearance.colorScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(content.name), \(Int(content.percent.rounded())) percent")
    }
}

private struct OSDSegments: View {
    static let count = 16
    let fraction: CGFloat
    let emptyOpacity: Double

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 1
            let width = (geometry.size.width - spacing * CGFloat(Self.count - 1)) / CGFloat(Self.count)
            HStack(spacing: spacing) {
                ForEach(0..<Self.count, id: \.self) { index in
                    let filled = min(max(fraction * CGFloat(Self.count) - CGFloat(index), 0), 1)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(emptyOpacity))
                        RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: width * filled)
                    }
                    .frame(width: width)
                }
            }
        }
    }
}
