import CoreGraphics
import Foundation

protocol TitleBarContextResolving {
    func resolveTitleBarInteraction(at location: CGPoint) -> TitleBarInteractionContext?
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
    }

    private let contextResolver: TitleBarContextResolving
    private let managedStateChecker: ManagedMaximizedStateChecking
    private let diagnostics: DebugDiagnostics
    private let maxMovement: CGFloat

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
        configuration: InterceptionConfiguration
    ) -> TitleBarInterceptionDecision {
        guard let context = contextResolver.resolveTitleBarInteraction(at: location) else {
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

        pendingDrag = PendingDrag(context: context, location: location)
        return .passThrough
    }

    func handleMouseDragged(location: CGPoint) -> TitleBarInterceptionDecision {
        guard let pendingDrag else {
            return .passThrough
        }

        let movedDistance = hypot(location.x - pendingDrag.location.x, location.y - pendingDrag.location.y)
        guard movedDistance > maxMovement else {
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
