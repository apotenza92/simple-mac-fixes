import ApplicationServices
import CoreGraphics
import XCTest
@testable import MaximizeFeature

final class TitleBarInterceptionControllerTests: XCTestCase {
    func testDoubleClickStillTriggersPerformActionWhenFullScreenIsSelected() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext()
        let managedStateChecker = ManagedStateCheckerSpy()
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics()
        )

        let decision = controller.handleMouseDown(
            location: CGPoint(x: 20, y: 20),
            clickCount: 2,
            configuration: InterceptionConfiguration(selectedAction: .fullScreen, diagnosticsEnabled: false)
        )

        guard case .performAction(let context) = decision else {
            return XCTFail("Expected performAction for titlebar double-click")
        }
        XCTAssertEqual(context.windowIdentifier, "fixture-window")
    }

    func testSingleClickPassesThroughWhenFullScreenSelectedAndWindowIsNotManagedMaximized() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext()
        let managedStateChecker = ManagedStateCheckerSpy(isManagedMaximized: false)
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics()
        )

        let decision = controller.handleMouseDown(
            location: CGPoint(x: 10, y: 10),
            clickCount: 1,
            configuration: InterceptionConfiguration(selectedAction: .fullScreen, diagnosticsEnabled: false)
        )

        assertDecision(decision, equals: .passThrough)
    }

    func testDoubleClickTriggersPerformActionAndConsumesMouseUp() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext()
        let managedStateChecker = ManagedStateCheckerSpy()
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics()
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 20, y: 20),
            clickCount: 2,
            configuration: InterceptionConfiguration(selectedAction: .maximize, diagnosticsEnabled: false)
        )
        let mouseUp = controller.handleMouseUp()

        guard case .performAction(let context) = mouseDown else {
            return XCTFail("Expected performAction for titlebar double-click")
        }
        XCTAssertEqual(context.windowIdentifier, "fixture-window")
        assertDecision(mouseUp, equals: .consume)
    }

    func testDragBeyondThresholdTriggersDragRestore() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext()
        let managedStateChecker = ManagedStateCheckerSpy()
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics(),
            maxMovement: 4
        )

        _ = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 30),
            clickCount: 1,
            configuration: InterceptionConfiguration(selectedAction: .maximize, diagnosticsEnabled: false)
        )
        let dragDecision = controller.handleMouseDragged(location: CGPoint(x: 108, y: 30))

        guard case .dragRestore(let context, let cursorLocation) = dragDecision else {
            return XCTFail("Expected dragRestore decision")
        }
        XCTAssertEqual(context.windowIdentifier, "fixture-window")
        XCTAssertEqual(cursorLocation, CGPoint(x: 108, y: 30))
    }

    func testDragRestoreStillArmsWhenFullScreenSelectedButWindowIsManagedMaximized() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext()
        let managedStateChecker = ManagedStateCheckerSpy(isManagedMaximized: true)
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics(),
            maxMovement: 4
        )

        _ = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 30),
            clickCount: 1,
            configuration: InterceptionConfiguration(selectedAction: .fullScreen, diagnosticsEnabled: false)
        )
        let dragDecision = controller.handleMouseDragged(location: CGPoint(x: 108, y: 30))

        guard case .dragRestore(let context, let cursorLocation) = dragDecision else {
            return XCTFail("Expected dragRestore decision")
        }
        XCTAssertEqual(context.windowIdentifier, "fixture-window")
        XCTAssertEqual(cursorLocation, CGPoint(x: 108, y: 30))
    }

    func testDragWithinThresholdPassesThrough() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext()
        let managedStateChecker = ManagedStateCheckerSpy()
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics(),
            maxMovement: 4
        )

        _ = controller.handleMouseDown(
            location: CGPoint(x: 100, y: 30),
            clickCount: 1,
            configuration: InterceptionConfiguration(selectedAction: .maximize, diagnosticsEnabled: false)
        )

        let dragDecision = controller.handleMouseDragged(location: CGPoint(x: 102, y: 32))
        assertDecision(dragDecision, equals: .passThrough)
    }

    func testDoubleClickUsesActivationRectOutsideDraggableRect() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext(
            draggableRect: CGRect(x: 10, y: 10, width: 500, height: 40),
            activationRect: CGRect(x: 10, y: 10, width: 500, height: 80),
            allowsActivationOutsideDraggableRect: true
        )
        let managedStateChecker = ManagedStateCheckerSpy()
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics()
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 20, y: 70),
            clickCount: 2,
            configuration: InterceptionConfiguration(selectedAction: .maximize, diagnosticsEnabled: false)
        )

        guard case .performAction(let context) = mouseDown else {
            return XCTFail("Expected performAction for activation rect double-click")
        }
        XCTAssertEqual(context.windowIdentifier, "fixture-window")
    }

    func testDoubleClickInActivationRectOutsideDraggableRectPassesThroughWithoutSupplementaryPermission() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext(
            draggableRect: CGRect(x: 10, y: 10, width: 500, height: 40),
            activationRect: CGRect(x: 10, y: 10, width: 500, height: 80),
            allowsActivationOutsideDraggableRect: false
        )
        let managedStateChecker = ManagedStateCheckerSpy()
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics()
        )

        let mouseDown = controller.handleMouseDown(
            location: CGPoint(x: 20, y: 70),
            clickCount: 2,
            configuration: InterceptionConfiguration(selectedAction: .maximize, diagnosticsEnabled: false)
        )
        let mouseUp = controller.handleMouseUp()

        assertDecision(mouseDown, equals: .passThrough)
        assertDecision(mouseUp, equals: .passThrough)
    }

    func testSingleClickInActivationRectOutsideDraggableRectDoesNotArmDragRestore() {
        let resolver = TitleBarResolverSpy()
        resolver.context = Self.makeContext(
            draggableRect: CGRect(x: 10, y: 10, width: 500, height: 40),
            activationRect: CGRect(x: 10, y: 10, width: 500, height: 80)
        )
        let managedStateChecker = ManagedStateCheckerSpy()
        let controller = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: managedStateChecker,
            diagnostics: DebugDiagnostics(),
            maxMovement: 4
        )

        _ = controller.handleMouseDown(
            location: CGPoint(x: 20, y: 70),
            clickCount: 1,
            configuration: InterceptionConfiguration(selectedAction: .maximize, diagnosticsEnabled: false)
        )
        let dragDecision = controller.handleMouseDragged(location: CGPoint(x: 30, y: 70))

        assertDecision(dragDecision, equals: .passThrough)
    }

    private func assertDecision(_ decision: TitleBarInterceptionDecision, equals expected: TitleBarInterceptionDecision) {
        switch (decision, expected) {
        case (.passThrough, .passThrough), (.consume, .consume):
            return
        default:
            XCTFail("Unexpected decision \(decision) != \(expected)")
        }
    }

    private static func makeContext(
        draggableRect: CGRect = CGRect(x: 10, y: 10, width: 500, height: 40),
        activationRect: CGRect? = nil,
        allowsActivationOutsideDraggableRect: Bool = false
    ) -> TitleBarInteractionContext {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windowContext = ClickedWindowContext(
            appName: "Fixture",
            bundleIdentifier: "com.example.fixture",
            pid: ProcessInfo.processInfo.processIdentifier,
            clickLocation: CGPoint(x: 100, y: 100),
            buttonElement: element,
            windowElement: element,
            windowIdentifier: "fixture-window",
            windowNumber: 1,
            windowTitle: "Fixture",
            elementRole: "AXWindow",
            elementSubrole: kAXStandardWindowSubrole as String,
            availableActions: [],
            windowFrame: CGRect(x: 10, y: 10, width: 500, height: 400),
            canSetPosition: true,
            canSetSize: true,
            isResizable: true,
            isFullScreen: false,
            isMainWindow: true,
            isFocusedWindow: true
        )
        return TitleBarInteractionContext(
            draggableRect: draggableRect,
            activationRect: activationRect ?? draggableRect,
            allowsActivationOutsideDraggableRect: allowsActivationOutsideDraggableRect,
            windowContext: windowContext
        )
    }
}

private final class TitleBarResolverSpy: TitleBarContextResolving {
    var context: TitleBarInteractionContext?

    func resolveTitleBarInteraction(at location: CGPoint) -> TitleBarInteractionContext? {
        context
    }
}

private struct ManagedStateCheckerSpy: ManagedMaximizedStateChecking {
    var isManagedMaximized = false

    func isCurrentlyManagedMaximized(_ context: ClickedWindowContext) -> Bool {
        isManagedMaximized
    }
}
