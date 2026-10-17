import AppKit
import SwiftUI

enum ControlMaterial: String, CaseIterable, Identifiable {
    case regular = "Regular"
    case clear = "Clear"
    case classicHUD = "Classic HUD"
    case systemMenu = "System Menu"

    var id: String { rawValue }
    static let preferenceKey = "devControlMaterial"
    static var isDevelopmentBuild: Bool {
        AppIdentity.isDevelopmentBuild
    }
}

/// Menu windows can inherit a vibrant appearance independently of the app.
/// Give the menu and HUD one explicit, live source for their color scheme.
@MainActor
final class ControlAppearance: ObservableObject {
    static let shared = ControlAppearance()
    @Published private(set) var colorScheme: ColorScheme
    private var observation: NSKeyValueObservation?

    private init() {
        colorScheme = Self.scheme(for: NSApp.effectiveAppearance)
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                let scheme = Self.scheme(for: NSApp.effectiveAppearance)
                if self?.colorScheme != scheme { self?.colorScheme = scheme }
            }
        }
    }

    private static func scheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension View {
    func controlMenuSurface() -> some View {
        modifier(ControlMenuSurface())
    }

    func controlGlass() -> some View {
        modifier(ControlGlass())
    }

    func hudGlass() -> some View {
        modifier(ControlGlass(overrideMaterial: .regular))
    }

    @ViewBuilder
    func clearControlWindowBackground() -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(.clear, for: .window)
        } else {
            self
        }
    }
}

private struct ControlMenuSurface: ViewModifier {
    // There is no live material picker; avoid a defaults subscription in every surface.
    private static let selection = UserDefaults.standard.string(forKey: ControlMaterial.preferenceKey) ?? ControlMaterial.systemMenu.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        if !ControlMaterial.isDevelopmentBuild || Self.selection == ControlMaterial.systemMenu.rawValue {
            // Baseline: retain MenuBarExtra's own background without added glass.
            content
        } else {
            content.controlGlass().clearControlWindowBackground()
        }
    }
}

private struct ControlGlass: ViewModifier {
    var overrideMaterial: ControlMaterial? = nil
    private static let selectedMaterial = UserDefaults.standard.string(forKey: ControlMaterial.preferenceKey) ?? ControlMaterial.regular.rawValue

    private var material: ControlMaterial {
        if let overrideMaterial { return overrideMaterial }
        guard ControlMaterial.isDevelopmentBuild else { return .regular }
        return ControlMaterial(rawValue: Self.selectedMaterial) ?? .regular
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if material == .systemMenu {
            content.background { ClassicHUDMaterial(material: .menu).clipShape(shape) }
        } else if #available(macOS 26.0, *), material != .classicHUD {
            content.glassEffect(material == .clear ? .clear : .regular, in: shape)
        } else {
            content.background { ClassicHUDMaterial().clipShape(shape) }
        }
    }
}

private struct ClassicHUDMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
    }
}
