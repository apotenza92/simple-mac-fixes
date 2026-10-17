import ApplicationServices
import CoreGraphics
import XCTest
@testable import MaximizeFeature

final class WindowActionEngineTests: XCTestCase {
    func testFullScreenUsesDirectButtonAction() {
        XCTAssertEqual(WindowActionEngine.plan(for: .fullScreen), [.fullScreen])

        let strategy = MaximizePerformerStub(result: Self.successResult())
        let fullScreenStrategy = FullScreenPerformerStub(result: FullScreenResult(
            succeeded: true,
            notes: ["full screen succeeded"],
            failureDisposition: .dropInterceptedClick
        ))
        let engine = WindowActionEngine(
            maximizeStrategy: strategy,
            fullScreenStrategy: fullScreenStrategy,
            diagnostics: DebugDiagnostics()
        )

        let outcome = engine.perform(mode: .fullScreen, context: Self.makeContext())

        XCTAssertTrue(outcome.handled)
        XCTAssertEqual(outcome.chosenPath, .fullScreen)
        XCTAssertEqual(outcome.failureDisposition, .dropInterceptedClick)
        XCTAssertNil(outcome.interceptionKey)
        XCTAssertNil(outcome.mutationExpectation)
        XCTAssertEqual(strategy.performCallCount, 0)
        XCTAssertEqual(fullScreenStrategy.performCallCount, 1)
    }

    func testFullScreenFallsBackToReplayWhenDirectButtonActionFails() {
        let strategy = MaximizePerformerStub(result: Self.successResult())
        let fullScreenStrategy = FullScreenPerformerStub(result: FullScreenResult(
            succeeded: false,
            notes: ["full screen failed"],
            failureDisposition: .replayOriginalClick
        ))
        let engine = WindowActionEngine(
            maximizeStrategy: strategy,
            fullScreenStrategy: fullScreenStrategy,
            diagnostics: DebugDiagnostics()
        )

        let outcome = engine.perform(mode: .fullScreen, context: Self.makeContext())

        XCTAssertFalse(outcome.handled)
        XCTAssertEqual(outcome.chosenPath, .fullScreen)
        XCTAssertEqual(outcome.failureDisposition, .replayOriginalClick)
        XCTAssertNil(outcome.interceptionKey)
        XCTAssertNil(outcome.mutationExpectation)
        XCTAssertEqual(strategy.performCallCount, 0)
        XCTAssertEqual(fullScreenStrategy.performCallCount, 1)
    }

    func testMaximizeInvokesDeterministicStrategyOnly() {
        XCTAssertEqual(WindowActionEngine.plan(for: .maximize), [.maximize])

        let strategy = MaximizePerformerStub(result: Self.successResult())
        let engine = WindowActionEngine(maximizeStrategy: strategy, diagnostics: DebugDiagnostics())

        let outcome = engine.perform(mode: .maximize, context: Self.makeContext())

        XCTAssertTrue(outcome.handled)
        XCTAssertEqual(outcome.chosenPath, .maximize)
        XCTAssertEqual(outcome.failureDisposition, .dropInterceptedClick)
        XCTAssertEqual(outcome.interceptionKey, Self.makeContext().interceptionKey)
        XCTAssertEqual(outcome.mutationExpectation, Self.successResult().mutationExpectation)
        XCTAssertEqual(strategy.performCallCount, 1)
    }

    func testMaximizeSkipsNonResizableWindows() {
        let strategy = MaximizePerformerStub(result: Self.successResult())
        let engine = WindowActionEngine(maximizeStrategy: strategy, diagnostics: DebugDiagnostics())

        let outcome = engine.perform(mode: .maximize, context: Self.makeContext(isResizable: false))

        XCTAssertFalse(outcome.handled)
        XCTAssertNil(outcome.chosenPath)
        XCTAssertEqual(outcome.failureDisposition, .dropInterceptedClick)
        XCTAssertNil(outcome.interceptionKey)
        XCTAssertNil(outcome.mutationExpectation)
        XCTAssertEqual(strategy.performCallCount, 0)
        XCTAssertTrue(outcome.notes.contains { $0.contains("not appear to be resizable") })
    }

    func testMaximizePropagatesMissingFrameFailure() {
        let strategy = MaximizePerformerStub(result: MaximizeResult(
            succeeded: false,
            appliedRect: nil,
            restored: false,
            positionApplied: false,
            postApplyFrame: nil,
            mutationExpectation: nil,
            notes: ["Window frame unavailable."]
        ))
        let engine = WindowActionEngine(maximizeStrategy: strategy, diagnostics: DebugDiagnostics())

        let outcome = engine.perform(mode: .maximize, context: Self.makeContext(windowFrame: nil))

        XCTAssertFalse(outcome.handled)
        XCTAssertEqual(outcome.chosenPath, .maximize)
        XCTAssertEqual(outcome.failureDisposition, .dropInterceptedClick)
        XCTAssertNil(outcome.interceptionKey)
        XCTAssertNil(outcome.mutationExpectation)
        XCTAssertEqual(strategy.performCallCount, 1)
        XCTAssertEqual(outcome.notes, ["Window frame unavailable."])
    }

    private static func successResult() -> MaximizeResult {
        MaximizeResult(
            succeeded: true,
            appliedRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            restored: false,
            positionApplied: true,
            postApplyFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            mutationExpectation: ManagedWindowMutationExpectation(
                sourceFrame: CGRect(x: 10, y: 10, width: 500, height: 400),
                destinationFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                observedFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                restored: false
            ),
            notes: ["maximize succeeded"]
        )
    }

    private static func makeContext(
        windowFrame: CGRect? = CGRect(x: 10, y: 10, width: 500, height: 400),
        isResizable: Bool = true
    ) -> ClickedWindowContext {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        return ClickedWindowContext(
            appName: "Fixture",
            bundleIdentifier: "com.example.fixture",
            pid: ProcessInfo.processInfo.processIdentifier,
            clickLocation: CGPoint(x: 100, y: 100),
            buttonElement: element,
            windowElement: element,
            windowIdentifier: "fixture-window",
            windowNumber: 1,
            windowTitle: "Fixture",
            elementRole: "AXButton",
            elementSubrole: "AXZoomButton",
            availableActions: ["AXPress"],
            windowFrame: windowFrame,
            canSetPosition: true,
            canSetSize: true,
            isResizable: isResizable,
            isFullScreen: false,
            isMainWindow: true,
            isFocusedWindow: true
        )
    }
}

private final class MaximizePerformerStub: MaximizePerforming {
    let result: MaximizeResult
    private(set) var performCallCount = 0

    init(result: MaximizeResult) {
        self.result = result
    }

    func perform(on context: ClickedWindowContext) -> MaximizeResult {
        performCallCount += 1
        return result
    }
}

private final class FullScreenPerformerStub: FullScreenPerforming {
    let result: FullScreenResult
    private(set) var performCallCount = 0

    init(result: FullScreenResult) {
        self.result = result
    }

    func perform(on context: ClickedWindowContext) -> FullScreenResult {
        performCallCount += 1
        return result
    }
}
