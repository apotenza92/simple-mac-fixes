import CoreGraphics
import Foundation

protocol GreenButtonContextResolving {
    func resolveGreenButtonClick(at location: CGPoint) -> ClickedWindowContext?
}

struct InterceptionConfiguration: Equatable {
    var selectedAction: WindowActionMode
    var diagnosticsEnabled: Bool
}

struct PendingWindowAction {
    let context: ClickedWindowContext
    let mode: WindowActionMode
}

enum MouseInterceptionDecision {
    case passThrough
    case consume(ClickedWindowContext)
    case flushBufferedEvents
    case performAction(PendingWindowAction)
}

final class GreenButtonInterceptionController {
    private struct PendingIntercept {
        let context: ClickedWindowContext
        let mode: WindowActionMode
        let location: CGPoint
        let timestamp: TimeInterval
    }

    private let contextResolver: GreenButtonContextResolving
    private let diagnostics: DebugDiagnostics
    private let maxClickDuration: TimeInterval
    private let maxMovement: CGFloat

    private var pendingIntercept: PendingIntercept?

    init(
        contextResolver: GreenButtonContextResolving,
        diagnostics: DebugDiagnostics,
        maxClickDuration: TimeInterval = 0.35,
        maxMovement: CGFloat = 4
    ) {
        self.contextResolver = contextResolver
        self.diagnostics = diagnostics
        self.maxClickDuration = maxClickDuration
        self.maxMovement = maxMovement
    }

    func reset() {
        pendingIntercept = nil
    }

    func handleMouseDown(
        location: CGPoint,
        timestamp: TimeInterval,
        optionPressed: Bool,
        configuration: InterceptionConfiguration
    ) -> MouseInterceptionDecision {
        guard configuration.selectedAction == .maximize || optionPressed else {
            return .passThrough
        }

        guard let context = contextResolver.resolveGreenButtonClick(at: location) else {
            return .passThrough
        }

        if context.isFullScreen {
            if configuration.diagnosticsEnabled {
                diagnostics.logClickContext(
                    context,
                    chosenPath: "pass-through-full-screen",
                    notes: [AppStrings.greenButtonFullScreenPassThroughMessage]
                )
            }
            return .passThrough
        }

        let mode = optionPressed ? configuration.selectedAction.opposite : configuration.selectedAction

        pendingIntercept = PendingIntercept(
            context: context,
            mode: mode,
            location: location,
            timestamp: timestamp
        )

        if configuration.diagnosticsEnabled {
            diagnostics.logClickContext(context, chosenPath: "captured-down")
        }

        return .consume(context)
    }

    func handleMouseDragged(location: CGPoint) -> MouseInterceptionDecision {
        guard let pendingIntercept else {
            return .passThrough
        }

        let movedDistance = hypot(location.x - pendingIntercept.location.x, location.y - pendingIntercept.location.y)
        guard movedDistance > maxMovement else {
            return .consume(pendingIntercept.context)
        }

        self.pendingIntercept = nil
        diagnostics.logMessage(AppStrings.greenButtonDragFlushMessage)
        return .flushBufferedEvents
    }

    func handleHoldTimeout(timestamp: TimeInterval) -> MouseInterceptionDecision {
        guard let pendingIntercept else {
            return .passThrough
        }

        guard timestamp - pendingIntercept.timestamp > maxClickDuration else {
            return .consume(pendingIntercept.context)
        }

        self.pendingIntercept = nil
        diagnostics.logMessage(AppStrings.greenButtonHoldFlushMessage)
        return .flushBufferedEvents
    }

    func handleMouseUp(location: CGPoint, timestamp: TimeInterval) -> MouseInterceptionDecision {
        guard let pending = pendingIntercept else {
            return .passThrough
        }
        pendingIntercept = nil

        let duration = timestamp - pending.timestamp
        let movedDistance = hypot(location.x - pending.location.x, location.y - pending.location.y)
        if duration > maxClickDuration || movedDistance > maxMovement {
            diagnostics.logMessage(AppStrings.greenButtonThresholdFlushMessage)
            return .flushBufferedEvents
        }

        return .performAction(PendingWindowAction(context: pending.context, mode: pending.mode))
    }
}

extension AccessibilityService: GreenButtonContextResolving {}
