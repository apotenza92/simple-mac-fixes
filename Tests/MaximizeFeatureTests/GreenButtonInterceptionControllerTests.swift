import ApplicationServices
import CoreGraphics
import XCTest
@testable import MaximizeFeature

final class GreenButtonInterceptionControllerTests: XCTestCase {
    func testBestFrameMatchIndexPrefersNearestMatchingButtonFrame() {
        let frames = [
            CGRect(x: 10, y: 10, width: 16, height: 16),
            CGRect(x: 40, y: 10, width: 16, height: 16)
        ]

        let match = AccessibilityService.bestFrameMatchIndex(
            for: CGPoint(x: 46, y: 18),
            candidateFrames: frames,
            tolerance: 6
        )

        XCTAssertEqual(match, 1)
    }

    func testClicksInTheGreenButtonsTileMenuAreNotGreenButtonClicks() {
        let button = CGRect(x: 52, y: 10, width: 14, height: 14)
        XCTAssertTrue(AccessibilityService.isClick(at: CGPoint(x: 59, y: 17), onButtonFrame: button))
        XCTAssertTrue(AccessibilityService.isClick(at: CGPoint(x: 70, y: 28), onButtonFrame: button))
        // Move & Resize and Fill & Arrange tiles sit well below the button.
        XCTAssertFalse(AccessibilityService.isClick(at: CGPoint(x: 80, y: 60), onButtonFrame: button))
        XCTAssertFalse(AccessibilityService.isClick(at: CGPoint(x: 150, y: 120), onButtonFrame: button))
        XCTAssertTrue(AccessibilityService.isClick(at: CGPoint(x: 150, y: 120), onButtonFrame: nil))
    }

    func testBestFrameMatchIndexReturnsNilWhenPointMissesAllCandidates() {
        let frames = [CGRect(x: 10, y: 10, width: 16, height: 16)]

        let match = AccessibilityService.bestFrameMatchIndex(
            for: CGPoint(x: 60, y: 60),
            candidateFrames: frames,
            tolerance: 4
        )

        XCTAssertNil(match)
    }

    func testTrafficLightHotZoneCoversTopLeftWindowControlsArea() {
        let windowFrame = CGRect(x: 100, y: 200, width: 900, height: 700)
        let hotZone = AccessibilityService.trafficLightHotZone(for: windowFrame)

        XCTAssertTrue(hotZone.contains(CGPoint(x: 112, y: 212)))
        XCTAssertFalse(hotZone.contains(CGPoint(x: 112, y: 888)))
    }

    func testTrafficLightHotZoneExcludesFarRightTitlebarArea() {
        let windowFrame = CGRect(x: 100, y: 200, width: 900, height: 700)
        let hotZone = AccessibilityService.trafficLightHotZone(for: windowFrame)

        XCTAssertFalse(hotZone.contains(CGPoint(x: 600, y: 212)))
    }

    func testMouseDownPassesThroughWhenFullScreenSelected() {
        let resolver = ResolverSpy()
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics
        )

        let decision = controller.handleMouseDown(
            location: CGPoint(x: 12, y: 24),
            timestamp: 1,
            optionPressed: false,
            configuration: InterceptionConfiguration(
                selectedAction: .fullScreen,
                diagnosticsEnabled: false
            )
        )

        assertDecision(decision, equals: .passThrough)
        XCTAssertEqual(resolver.resolveCallCount, 0)
    }

    func testCleanClickConsumesThenReturnsPendingAction() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext()
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 200),
            timestamp: 10,
            optionPressed: false,
            configuration: InterceptionConfiguration(
                selectedAction: .maximize,
                diagnosticsEnabled: true
            )
        )
        let mouseUp = controller.handleMouseUp(location: CGPoint(x: 101, y: 200), timestamp: 10.2)

        assertConsumes(mouseDown)
        guard case .performAction(let pendingAction) = mouseUp else {
            return XCTFail("Expected performAction decision")
        }
        XCTAssertEqual(pendingAction.mode, .maximize)
        XCTAssertEqual(pendingAction.context.windowIdentifier, Self.makeContext().windowIdentifier)
    }

    func testOptionClickEntersFullScreenInsteadOfMaximizing() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: DebugDiagnostics()
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 200),
            timestamp: 10,
            optionPressed: true,
            configuration: InterceptionConfiguration(selectedAction: .maximize, diagnosticsEnabled: false)
        )
        let mouseUp = controller.handleMouseUp(location: CGPoint(x: 100, y: 200), timestamp: 10.1)

        assertConsumes(mouseDown)
        guard case .performAction(let pendingAction) = mouseUp else {
            return XCTFail("Expected performAction decision")
        }
        XCTAssertEqual(pendingAction.mode, .fullScreen)
    }

    func testDragBeyondThresholdFlushesBufferedEventsImmediately() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext()
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics,
            maxClickDuration: 0.35,
            maxMovement: 4
        )

        _ = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 100),
            timestamp: 5,
            optionPressed: false,
            configuration: InterceptionConfiguration(
                selectedAction: .maximize,
                diagnosticsEnabled: false
            )
        )
        let dragDecision = controller.handleMouseDragged(location: CGPoint(x: 110, y: 100))
        let mouseUpDecision = controller.handleMouseUp(location: CGPoint(x: 110, y: 100), timestamp: 5.1)

        assertDecision(dragDecision, equals: .flushBufferedEvents)
        assertDecision(mouseUpDecision, equals: .passThrough)
    }

    func testHoldTimeoutFlushesBufferedEventsBeforeMouseUp() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext()
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics,
            maxClickDuration: 0.35,
            maxMovement: 4
        )

        _ = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 100),
            timestamp: 1,
            optionPressed: false,
            configuration: InterceptionConfiguration(
                selectedAction: .maximize,
                diagnosticsEnabled: false
            )
        )

        let timeoutDecision = controller.handleHoldTimeout(timestamp: 1.36)
        let mouseUpDecision = controller.handleMouseUp(location: CGPoint(x: 100, y: 100), timestamp: 1.6)

        assertDecision(timeoutDecision, equals: .flushBufferedEvents)
        assertDecision(mouseUpDecision, equals: .passThrough)
    }

    func testMouseDraggedWithinThresholdKeepsConsuming() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext()
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics,
            maxClickDuration: 0.35,
            maxMovement: 4
        )

        _ = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 100),
            timestamp: 1,
            optionPressed: false,
            configuration: InterceptionConfiguration(
                selectedAction: .maximize,
                diagnosticsEnabled: false
            )
        )

        let dragDecision = controller.handleMouseDragged(location: CGPoint(x: 102, y: 101))

        assertConsumes(dragDecision)
    }

    func testOptionClickInFullScreenModeCapturesAndPerformsMaximize() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext()
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 200),
            timestamp: 10,
            optionPressed: true,
            configuration: InterceptionConfiguration(
                selectedAction: .fullScreen,
                diagnosticsEnabled: false
            )
        )
        let mouseUp = controller.handleMouseUp(location: CGPoint(x: 100, y: 200), timestamp: 10.1)

        assertConsumes(mouseDown)
        guard case .performAction(let pendingAction) = mouseUp else {
            return XCTFail("Expected performAction decision")
        }
        XCTAssertEqual(pendingAction.mode, .maximize)
    }

    func testOptionClickInMaximizeModeCapturesAndPerformsFullScreen() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext()
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 200),
            timestamp: 10,
            optionPressed: true,
            configuration: InterceptionConfiguration(
                selectedAction: .maximize,
                diagnosticsEnabled: false
            )
        )
        let mouseUp = controller.handleMouseUp(location: CGPoint(x: 100, y: 200), timestamp: 10.1)

        assertConsumes(mouseDown)
        guard case .performAction(let pendingAction) = mouseUp else {
            return XCTFail("Expected performAction decision")
        }
        XCTAssertEqual(pendingAction.mode, .fullScreen)
    }

    func testMouseDownPassesThroughWhenWindowAlreadyInFullScreen() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext(isFullScreen: true)
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 200),
            timestamp: 10,
            optionPressed: false,
            configuration: InterceptionConfiguration(
                selectedAction: .maximize,
                diagnosticsEnabled: false
            )
        )
        let mouseUp = controller.handleMouseUp(location: CGPoint(x: 100, y: 200), timestamp: 10.1)

        assertDecision(mouseDown, equals: .passThrough)
        assertDecision(mouseUp, equals: .passThrough)
    }

    func testOptionClickPassesThroughWhenWindowAlreadyInFullScreen() {
        let resolver = ResolverSpy()
        resolver.context = Self.makeContext(isFullScreen: true)
        let diagnostics = DebugDiagnostics()
        let controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 200),
            timestamp: 10,
            optionPressed: true,
            configuration: InterceptionConfiguration(
                selectedAction: .maximize,
                diagnosticsEnabled: false
            )
        )
        let mouseUp = controller.handleMouseUp(location: CGPoint(x: 100, y: 200), timestamp: 10.1)

        assertDecision(mouseDown, equals: .passThrough)
        assertDecision(mouseUp, equals: .passThrough)
    }

    private func assertDecision(_ decision: MouseInterceptionDecision, equals expected: MouseInterceptionDecision) {
        switch (decision, expected) {
        case (.passThrough, .passThrough),
             (.flushBufferedEvents, .flushBufferedEvents):
            return
        default:
            XCTFail("Unexpected decision \(decision) != \(expected)")
        }
    }

    private func assertConsumes(_ decision: MouseInterceptionDecision) {
        guard case .consume(_) = decision else {
            return XCTFail("Expected consume decision, got \(decision)")
        }
    }

    private static func makeContext(isFullScreen: Bool = false) -> ClickedWindowContext {
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
            windowFrame: CGRect(x: 10, y: 10, width: 500, height: 400),
            canSetPosition: true,
            canSetSize: true,
            isResizable: true,
            isFullScreen: isFullScreen,
            isMainWindow: true,
            isFocusedWindow: true
        )
    }
}

private final class ResolverSpy: GreenButtonContextResolving {
    var context: ClickedWindowContext?
    private(set) var resolveCallCount = 0

    func resolveGreenButtonClick(at location: CGPoint) -> ClickedWindowContext? {
        resolveCallCount += 1
        return context
    }
}
