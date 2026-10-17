import Foundation

/// The green button and a title-bar double-click maximize the window instead
/// of entering full screen. Option-click keeps full screen available.
///
/// Ported from Macsimize; everything else in this module is internal.
public final class GreenButtonMaximizeFeature {
    private let diagnostics = DebugDiagnostics()
    private lazy var accessibility = AccessibilityService(diagnostics: diagnostics)
    private lazy var maximizeStrategy = MaximizeStrategy(frameStore: WindowFrameStore(), diagnostics: diagnostics)
    private lazy var service = EventTapService(
        accessibilityService: accessibility,
        actionEngine: WindowActionEngine(maximizeStrategy: maximizeStrategy, diagnostics: diagnostics),
        maximizeStrategy: maximizeStrategy,
        diagnostics: diagnostics
    )
    private var started = false

    public init() {
        diagnostics.setEnabledProvider { false }
    }

    public var isRunning: Bool { started }

    @discardableResult
    public func start() -> Bool {
        service.startIfPossible(selectedAction: .maximize, diagnosticsEnabled: false)
        started = service.hasEventTap
        return started
    }

    public func stop() {
        guard started else { return }
        service.stop(reason: nil)
        started = false
    }
}
