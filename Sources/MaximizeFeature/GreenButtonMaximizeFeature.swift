import ApplicationServices
import Foundation

/// The green button and a title-bar double-click maximize the window instead
/// of entering full screen. Option-click keeps full screen available.
///
/// Ported from Macsimize; everything else in this module is internal.
public final class GreenButtonMaximizeFeature {
    private let diagnostics = DebugDiagnostics()
    private lazy var accessibility = AccessibilityService(diagnostics: diagnostics)
    private let gapBox = GapBox()
    private lazy var maximizeStrategy = MaximizeStrategy(
        frameStore: WindowFrameStore(defaults: .standard),
        diagnostics: diagnostics,
        gap: { [gapBox] in gapBox.value }
    )
    private lazy var actionEngine = WindowActionEngine(maximizeStrategy: maximizeStrategy, diagnostics: diagnostics)
    private lazy var service = EventTapService(
        accessibilityService: accessibility,
        actionEngine: actionEngine,
        maximizeStrategy: maximizeStrategy,
        diagnostics: diagnostics
    )
    private var started = false
    private let electronAccessibility = ElectronAccessibility()

    public init() {
        diagnostics.setEnabledProvider { false }
    }

    public var isRunning: Bool { started }

    /// The space a maximized window leaves to the edges of its screen, in points.
    /// A window that is maximized already keeps its size until it is maximized again.
    public var gap: CGFloat {
        get { gapBox.value }
        set { gapBox.value = max(0, newValue) }
    }

    @discardableResult
    public func start() -> Bool {
        service.startIfPossible(selectedAction: .maximize, diagnosticsEnabled: false)
        started = service.hasEventTap
        if started {
            electronAccessibility.start()
        }
        return started
    }

    /// Does what clicking `window`'s green button does while this is on: maximize, or
    /// put back a window it maximized; Option asks for full screen instead, and a
    /// full-screen window leaves full screen. False when off, so the caller can fall
    /// back to the button's usual full screen. Call it off the main thread.
    public func pressGreenButton(of window: AXUIElement, optionPressed: Bool) -> Bool {
        guard started, let context = accessibility.context(forWindow: window) else { return false }
        if context.isFullScreen {
            return AXHelpers.set(boolAttribute: "AXFullScreen", value: false, on: window) == .success
        }
        return actionEngine.perform(mode: optionPressed ? .fullScreen : .maximize, context: context).handled
    }

    public func stop() {
        guard started else { return }
        service.stop(reason: nil)
        electronAccessibility.stop()
        started = false
    }
}

/// Read where windows are maximized, off the main thread.
private final class GapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CGFloat = 0

    var value: CGFloat {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
