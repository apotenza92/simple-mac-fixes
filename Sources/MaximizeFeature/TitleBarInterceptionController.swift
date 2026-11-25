import CoreGraphics
import Foundation

protocol TitleBarContextResolving {
    func resolveTitleBarInteraction(at location: CGPoint, isDoubleClick: Bool) -> TitleBarInteractionContext?
    /// `waitsLonger` for a question that a slow app must not lose (`BoundedContextResolver`).
    func resolveTitleBarInteraction(at location: CGPoint, isDoubleClick: Bool, waitsLonger: Bool) -> TitleBarInteractionContext?
}

extension TitleBarContextResolving {
    func resolveTitleBarInteraction(at location: CGPoint, isDoubleClick: Bool, waitsLonger: Bool) -> TitleBarInteractionContext? {
        resolveTitleBarInteraction(at: location, isDoubleClick: isDoubleClick)
    }
}

protocol ManagedMaximizedStateChecking {
    func isCurrentlyManagedMaximized(_ context: ClickedWindowContext) -> Bool
}

enum TitleBarInterceptionDecision {
    case passThrough
    case consume
    case performAction(ClickedWindowContext)
    case dragRestore(ClickedWindowContext, cursorLocation: CGPoint)
}

final class TitleBarInterceptionController {
    private struct PendingDrag {
        let context: TitleBarInteractionContext
        let location: CGPoint
        /// Set when the window stays where it is until the drag pulls it away.
        var isHeld = false
        var lastLocation: CGPoint
        var lastTime: TimeInterval
    }

    private let contextResolver: TitleBarContextResolving
    private let managedStateChecker: ManagedMaximizedStateChecking
    private let diagnostics: DebugDiagnostics
    private let maxMovement: CGFloat
    /// How far the system lets the pointer go before a filled window comes away from
    /// its place: 33 to 36 points in drags at 100 to 360 points a second, measured on
    /// a window filled by the system. Faster drags came away sooner, after 12 to 18
    /// points at 400 and 850 points a second.
    static let heldMovement: CGFloat = 34
    static let heldMovementWhenFast: CGFloat = 12
    static let fastSpeed: CGFloat = 380

    private var pendingDrag: PendingDrag?
    private var shouldConsumeMouseUp = false

    init(
        contextResolver: TitleBarContextResolving,
        managedStateChecker: ManagedMaximizedStateChecking,
        diagnostics: DebugDiagnostics,
        maxMovement: CGFloat = 4
    ) {
        self.contextResolver = contextResolver
        self.managedStateChecker = managedStateChecker
        self.diagnostics = diagnostics
        self.maxMovement = maxMovement
    }

    func reset() {
        pendingDrag = nil
        shouldConsumeMouseUp = false
    }

    func handleMouseDown(
        location: CGPoint,
        clickCount: Int64,
        time: TimeInterval = ProcessInfo.processInfo.systemUptime,
        waitsLonger: Bool = false,
        configuration: InterceptionConfiguration
    ) -> TitleBarInterceptionDecision {
        guard let context = contextResolver.resolveTitleBarInteraction(
            at: location, isDoubleClick: clickCount >= 2, waitsLonger: waitsLonger
        ) else {
            pendingDrag = nil
            return .passThrough
        }

        if clickCount >= 2 {
            let isEligibleDoubleClick =
                context.draggableRect.contains(location)
                || (context.allowsActivationOutsideDraggableRect && context.activationRect.contains(location))
            guard isEligibleDoubleClick else {
                pendingDrag = nil
                shouldConsumeMouseUp = false
                return .passThrough
            }
            pendingDrag = nil
            shouldConsumeMouseUp = true
            diagnostics.logMessage(AppStrings.titleBarDoubleClickCaptured)
            return .performAction(context.windowContext)
        }

        guard context.draggableRect.contains(location) else {
            pendingDrag = nil
            return .passThrough
        }

        let shouldArmDragRestore = configuration.selectedAction == .maximize
            || managedStateChecker.isCurrentlyManagedMaximized(context.windowContext)
        guard shouldArmDragRestore else {
            pendingDrag = nil
            return .passThrough
        }

        pendingDrag = PendingDrag(
            context: context,
            location: location,
            lastLocation: location,
            lastTime: time
        )
        return .passThrough
    }

    /// The window a press on its title bar can restore, until the drag starts or ends.
    var pendingDragContext: ClickedWindowContext? {
        pendingDrag?.context.windowContext
    }

    /// Says that the pending drag's window holds still until the drag pulls it away,
    /// as a window filled by the system does.
    func holdPendingDrag() {
        pendingDrag?.isHeld = true
    }

    func handleMouseDragged(
        location: CGPoint,
        time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TitleBarInterceptionDecision {
        guard var pendingDrag else {
            return .passThrough
        }

        let movedDistance = hypot(location.x - pendingDrag.location.x, location.y - pendingDrag.location.y)
        var needed = maxMovement
        if pendingDrag.isHeld {
            let elapsed = time - pendingDrag.lastTime
            let step = hypot(location.x - pendingDrag.lastLocation.x, location.y - pendingDrag.lastLocation.y)
            let isFast = elapsed > 0 && step / elapsed >= Self.fastSpeed
            needed = isFast ? Self.heldMovementWhenFast : Self.heldMovement
            pendingDrag.lastLocation = location
            pendingDrag.lastTime = time
            self.pendingDrag = pendingDrag
        }
        guard movedDistance > needed else {
            return .passThrough
        }

        self.pendingDrag = nil
        return .dragRestore(pendingDrag.context.windowContext, cursorLocation: location)
    }

    func handleMouseUp() -> TitleBarInterceptionDecision {
        pendingDrag = nil
        guard shouldConsumeMouseUp else {
            return .passThrough
        }

        shouldConsumeMouseUp = false
        return .consume
    }
}

extension AccessibilityService: TitleBarContextResolving {}
extension MaximizeStrategy: ManagedMaximizedStateChecking {}
