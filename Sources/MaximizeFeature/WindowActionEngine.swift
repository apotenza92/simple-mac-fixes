import ApplicationServices
import Foundation

enum WindowActionStep: String, Equatable {
    case fullScreen
    case maximize
}

enum WindowActionFailureDisposition: Equatable {
    case replayOriginalClick
    case dropInterceptedClick
}

struct WindowActionOutcome: Equatable {
    let handled: Bool
    let chosenPath: WindowActionStep?
    let notes: [String]
    let failureDisposition: WindowActionFailureDisposition
    let interceptionKey: WindowInterceptionKey?
    let mutationExpectation: ManagedWindowMutationExpectation?
}

struct FullScreenResult: Equatable {
    let succeeded: Bool
    let notes: [String]
    let failureDisposition: WindowActionFailureDisposition
}

protocol FullScreenPerforming {
    func perform(on context: ClickedWindowContext) -> FullScreenResult
}

struct NativeFullScreenStrategy: FullScreenPerforming {
    func perform(on context: ClickedWindowContext) -> FullScreenResult {
        let fullScreenAttribute = "AXFullScreen" as CFString
        var fullScreenSettable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(context.windowElement, fullScreenAttribute, &fullScreenSettable)
        if settableError == .success && fullScreenSettable.boolValue {
            let error = AXUIElementSetAttributeValue(context.windowElement, fullScreenAttribute, kCFBooleanTrue)
            if error == .success {
                return FullScreenResult(
                    succeeded: true,
                    notes: [AppStrings.actionEngineFullScreenTriggered],
                    failureDisposition: .dropInterceptedClick
                )
            }

            return FullScreenResult(
                succeeded: false,
                notes: [AppStrings.actionEngineFullScreenAttributeFailed(code: error.rawValue)],
                failureDisposition: .replayOriginalClick
            )
        }

        guard context.availableActions.contains(kAXPressAction as String) else {
            return FullScreenResult(
                succeeded: false,
                notes: [AppStrings.actionEngineFullScreenActionUnavailable],
                failureDisposition: .replayOriginalClick
            )
        }

        let error = AXUIElementPerformAction(context.buttonElement, kAXPressAction as CFString)
        guard error == .success else {
            return FullScreenResult(
                succeeded: false,
                notes: [AppStrings.actionEngineFullScreenActionFailed(code: error.rawValue)],
                failureDisposition: .replayOriginalClick
            )
        }

        return FullScreenResult(
            succeeded: true,
            notes: [AppStrings.actionEngineFullScreenTriggered],
            failureDisposition: .dropInterceptedClick
        )
    }
}

final class WindowActionEngine {
    static let syntheticEventMarker: Int64 = 0x4D414353

    private let maximizeStrategy: any MaximizePerforming
    private let fullScreenStrategy: any FullScreenPerforming
    private let diagnostics: DebugDiagnostics

    init(
        maximizeStrategy: any MaximizePerforming,
        fullScreenStrategy: any FullScreenPerforming = NativeFullScreenStrategy(),
        diagnostics: DebugDiagnostics
    ) {
        self.maximizeStrategy = maximizeStrategy
        self.fullScreenStrategy = fullScreenStrategy
        self.diagnostics = diagnostics
    }

    func perform(mode: WindowActionMode, context: ClickedWindowContext) -> WindowActionOutcome {
        switch mode {
        case .fullScreen:
            let result = fullScreenStrategy.perform(on: context)
            if result.succeeded {
                diagnostics.logClickContext(context, chosenPath: WindowActionStep.fullScreen.rawValue, notes: result.notes)
                return WindowActionOutcome(
                    handled: true,
                    chosenPath: .fullScreen,
                    notes: result.notes,
                    failureDisposition: .dropInterceptedClick,
                    interceptionKey: nil,
                    mutationExpectation: nil
                )
            }

            diagnostics.logClickContext(context, chosenPath: "full-screen-failed", notes: result.notes)
            return WindowActionOutcome(
                handled: false,
                chosenPath: .fullScreen,
                notes: result.notes,
                failureDisposition: result.failureDisposition,
                interceptionKey: nil,
                mutationExpectation: nil
            )
        case .maximize:
            guard context.isResizable else {
                let notes = [AppStrings.actionEngineWindowNotResizable]
                diagnostics.logClickContext(context, chosenPath: "safety-skip", notes: notes)
                return WindowActionOutcome(
                    handled: false,
                    chosenPath: nil,
                    notes: notes,
                    failureDisposition: .dropInterceptedClick,
                    interceptionKey: nil,
                    mutationExpectation: nil
                )
            }

            let result = maximizeStrategy.perform(on: context)
            if result.succeeded {
                diagnostics.logClickContext(context, chosenPath: WindowActionStep.maximize.rawValue, notes: result.notes)
                return WindowActionOutcome(
                    handled: true,
                    chosenPath: .maximize,
                    notes: result.notes,
                    failureDisposition: .dropInterceptedClick,
                    interceptionKey: context.interceptionKey,
                    mutationExpectation: result.mutationExpectation
                )
            }

            diagnostics.logClickContext(context, chosenPath: "failed", notes: result.notes)
            return WindowActionOutcome(
                handled: false,
                chosenPath: .maximize,
                notes: result.notes,
                failureDisposition: .dropInterceptedClick,
                interceptionKey: nil,
                mutationExpectation: nil
            )
        }
    }

    static func plan(for mode: WindowActionMode) -> [WindowActionStep] {
        switch mode {
        case .fullScreen:
            return [.fullScreen]
        case .maximize:
            return [.maximize]
        }
    }
}
