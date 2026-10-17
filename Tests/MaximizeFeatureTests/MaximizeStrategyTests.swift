import XCTest
@testable import MaximizeFeature

final class MaximizeStrategyTests: XCTestCase {
    func testTargetRectUsesVisibleFrameOfMostOverlappedScreen() {
        let screens = [
            ScreenDescriptor(
                identifier: "left",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 50, width: 1512, height: 900)
            ),
            ScreenDescriptor(
                identifier: "right",
                frame: CGRect(x: 1512, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 1512, y: 32, width: 1728, height: 1060)
            )
        ]

        let windowFrame = CGRect(x: 1700, y: 100, width: 800, height: 800)
        XCTAssertEqual(
            MaximizeStrategy.targetRect(for: windowFrame, screens: screens),
            ScreenHelpers.accessibilityRect(forVisibleFrame: screens[1].visibleFrame, in: screens)
        )
    }

    func testTargetRectFallsBackToNearestScreenWhenWindowIsOffScreen() {
        let screens = [
            ScreenDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
            ),
            ScreenDescriptor(
                identifier: "secondary",
                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1040)
            )
        ]

        let offscreenWindow = CGRect(x: 3400, y: 120, width: 600, height: 400)
        XCTAssertEqual(
            MaximizeStrategy.targetRect(for: offscreenWindow, screens: screens),
            ScreenHelpers.accessibilityRect(forVisibleFrame: screens[1].visibleFrame, in: screens)
        )
    }

    func testTargetRectUsesAccessibilityScreenSelectionForStackedDisplays() {
        let screens = [
            ScreenDescriptor(
                identifier: "ultrawide",
                frame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                visibleFrame: CGRect(x: 0, y: 30, width: 3440, height: 1366)
            ),
            ScreenDescriptor(
                identifier: "laptop",
                frame: CGRect(x: 964, y: 1440, width: 1512, height: 982),
                visibleFrame: CGRect(x: 964, y: 1472, width: 1512, height: 950)
            )
        ]

        let laptopWindowFrame = CGRect(x: 1120, y: 120, width: 1100, height: 720)
        XCTAssertEqual(
            MaximizeStrategy.targetRect(for: laptopWindowFrame, screens: screens),
            ScreenHelpers.accessibilityRect(forVisibleFrame: screens[1].visibleFrame, in: screens)
        )
    }

    func testShouldRestoreWhenWindowAlreadyMatchesMaximizeTarget() {
        let currentFrame = CGRect(x: 0, y: 25, width: 1440, height: 840)
        let targetFrame = CGRect(x: 0, y: 25, width: 1440, height: 840)
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 100, y: 120, width: 900, height: 700),
            lastManagedMaximizeFrame: nil
        )

        XCTAssertTrue(MaximizeStrategy.shouldRestore(currentFrame: currentFrame, targetFrame: targetFrame, storedState: storedState))
    }

    func testDoesNotRestoreAfterManualResizeFollowingPreviousMaximize() {
        let targetFrame = CGRect(x: 0, y: 25, width: 1440, height: 840)
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 100, y: 120, width: 900, height: 700),
            lastManagedMaximizeFrame: targetFrame
        )
        let manuallyAdjustedFrame = CGRect(x: 40, y: 40, width: 1200, height: 700)

        XCTAssertFalse(MaximizeStrategy.shouldRestore(
            currentFrame: manuallyAdjustedFrame,
            targetFrame: targetFrame,
            storedState: storedState
        ))
    }

    func testRestoresWhenCurrentFrameIsNearLastAppliedMaximizeFrame() {
        let targetFrame = CGRect(x: 0, y: 25, width: 1440, height: 840)
        let lastAppliedMaximizeFrame = CGRect(x: 1, y: 24, width: 1439, height: 841)
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 100, y: 120, width: 900, height: 700),
            lastManagedMaximizeFrame: lastAppliedMaximizeFrame
        )

        XCTAssertTrue(MaximizeStrategy.shouldRestore(
            currentFrame: targetFrame,
            targetFrame: targetFrame,
            storedState: storedState
        ))
    }

    func testAccessibilityRectConvertsVisibleFrameIntoTopLeftDesktopCoordinates() {
        let screens = [
            ScreenDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949)
            ),
            ScreenDescriptor(
                identifier: "secondary",
                frame: CGRect(x: 1512, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 1512, y: 32, width: 1728, height: 1060)
            )
        ]

        XCTAssertEqual(
            ScreenHelpers.accessibilityRect(forVisibleFrame: screens[0].visibleFrame, in: screens),
            CGRect(x: 0, y: 168, width: 1512, height: 949)
        )
        XCTAssertEqual(
            ScreenHelpers.accessibilityRect(forVisibleFrame: screens[1].visibleFrame, in: screens),
            CGRect(x: 1512, y: 25, width: 1728, height: 1060)
        )
    }

    func testDragRestoreFrameKeepsCursorInsideRestoredFrame() {
        let currentFrame = CGRect(x: 0, y: 25, width: 1440, height: 840)
        let restoreFrame = CGRect(x: 100, y: 120, width: 900, height: 700)
        let cursorLocation = CGPoint(x: 1300, y: 200)

        let destination = MaximizeStrategy.dragRestoreFrame(
            currentFrame: currentFrame,
            restoreFrame: restoreFrame,
            cursorLocation: cursorLocation
        )

        XCTAssertEqual(destination.size, restoreFrame.size)
        XCTAssertEqual(destination.minY, currentFrame.minY)
        XCTAssertTrue(destination.contains(cursorLocation))
    }

    func testResolvedRestoreFrameReturnsExactStoredFrameWhenVisible() {
        let screens = [
            ScreenDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
            )
        ]
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 100, y: 120, width: 900, height: 700),
            lastManagedMaximizeFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
        )

        let resolution = MaximizeStrategy.resolvedRestoreFrame(
            currentFrame: CGRect(x: 0, y: 25, width: 1440, height: 840),
            storedState: storedState,
            screens: screens
        )

        XCTAssertEqual(resolution, RestoreFrameResolution(frame: storedState.restoreFrame, wasClamped: false))
    }

    func testResolvedRestoreFrameClampsOriginIntoVisibleFrame() {
        let screens = [
            ScreenDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
            )
        ]
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 1300, y: -50, width: 400, height: 600),
            lastManagedMaximizeFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
        )

        let resolution = MaximizeStrategy.resolvedRestoreFrame(
            currentFrame: CGRect(x: 0, y: 25, width: 1440, height: 840),
            storedState: storedState,
            screens: screens
        )

        XCTAssertEqual(resolution?.frame, CGRect(x: 1040, y: 35, width: 400, height: 600))
        XCTAssertEqual(resolution?.wasClamped, true)
    }

    func testResolvedRestoreFrameCapsSizeToVisibleFrame() {
        let screens = [
            ScreenDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
            )
        ]
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 10, y: 0, width: 1700, height: 1000),
            lastManagedMaximizeFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
        )

        let resolution = MaximizeStrategy.resolvedRestoreFrame(
            currentFrame: CGRect(x: 0, y: 25, width: 1440, height: 840),
            storedState: storedState,
            screens: screens
        )

        XCTAssertEqual(resolution?.frame, CGRect(x: 0, y: 35, width: 1440, height: 840))
        XCTAssertEqual(resolution?.wasClamped, true)
    }

    func testResolvedRestoreFrameFallsBackToCurrentManagedScreenWhenOriginalScreenIsGone() {
        let screens = [
            ScreenDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
            ),
            ScreenDescriptor(
                identifier: "secondary",
                frame: CGRect(x: 1440, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 1440, y: 32, width: 1728, height: 1060)
            )
        ]
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 4000, y: 300, width: 900, height: 700),
            lastManagedMaximizeFrame: CGRect(x: 1440, y: 25, width: 1728, height: 1060)
        )

        let resolution = MaximizeStrategy.resolvedRestoreFrame(
            currentFrame: CGRect(x: 1440, y: 25, width: 1728, height: 1060),
            storedState: storedState,
            screens: screens
        )

        XCTAssertEqual(resolution?.frame, CGRect(x: 2268, y: 300, width: 900, height: 700))
        XCTAssertEqual(resolution?.wasClamped, true)
    }

    func testResolvedRestoreFrameKeepsOriginalDisplayForStackedScreensUsingAccessibilityCoordinates() {
        let screens = [
            ScreenDescriptor(
                identifier: "ultrawide",
                frame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                visibleFrame: CGRect(x: 0, y: 30, width: 3440, height: 1366)
            ),
            ScreenDescriptor(
                identifier: "laptop",
                frame: CGRect(x: 964, y: 1440, width: 1512, height: 982),
                visibleFrame: CGRect(x: 964, y: 1472, width: 1512, height: 950)
            )
        ]
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 1100, y: 120, width: 1200, height: 700),
            lastManagedMaximizeFrame: ScreenHelpers.accessibilityRect(forVisibleFrame: screens[0].visibleFrame, in: screens)
        )

        let resolution = MaximizeStrategy.resolvedRestoreFrame(
            currentFrame: ScreenHelpers.accessibilityRect(forVisibleFrame: screens[0].visibleFrame, in: screens),
            storedState: storedState,
            screens: screens
        )

        XCTAssertEqual(resolution?.frame, storedState.restoreFrame)
        XCTAssertEqual(resolution?.wasClamped, false)
    }

    func testResolvedRestoreFrameUsesClampedDragRestoreDestination() {
        let screens = [
            ScreenDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
            )
        ]
        let storedState = StoredWindowFrameState(
            restoreFrame: CGRect(x: 100, y: 120, width: 1200, height: 700),
            lastManagedMaximizeFrame: CGRect(x: 0, y: 25, width: 1440, height: 840)
        )

        let resolution = MaximizeStrategy.resolvedRestoreFrame(
            currentFrame: CGRect(x: 0, y: 25, width: 1440, height: 840),
            storedState: storedState,
            screens: screens,
            cursorLocation: CGPoint(x: 1435, y: 80)
        )

        XCTAssertEqual(resolution?.frame, CGRect(x: 240, y: 35, width: 1200, height: 700))
        XCTAssertEqual(resolution?.wasClamped, true)
    }

    func testApplyManagedFrameWritesPositionThenSizeByDefault() {
        let destinationFrame = CGRect(x: 0, y: 30, width: 3440, height: 1335)
        var operations: [String] = []

        let result = MaximizeStrategy.applyManagedFrame(
            destinationFrame: destinationFrame,
            pid: 0,
            canSetPosition: true,
            settleTimeout: 0,
            settlePollInterval: 0,
            settleStablePollCount: 0,
            applyPosition: { origin in
                operations.append("position:\(Int(origin.x)),\(Int(origin.y))")
                return .success
            },
            applySize: { size in
                operations.append("size:\(Int(size.width)),\(Int(size.height))")
                return .success
            },
            readFrame: { destinationFrame }
        )

        XCTAssertEqual(operations, [
            "position:0,30",
            "size:3440,1335"
        ])
        XCTAssertTrue(result.positionApplied)
        XCTAssertEqual(result.finalSizeError, .success)
        XCTAssertEqual(result.postApplyFrame, destinationFrame)
    }

    func testApplyManagedFrameCanWriteSizeThenPositionThenSizeWhenRequested() {
        let destinationFrame = CGRect(x: 0, y: 30, width: 3440, height: 1335)
        var operations: [String] = []

        let result = MaximizeStrategy.applyManagedFrame(
            destinationFrame: destinationFrame,
            pid: 0,
            canSetPosition: true,
            adjustSizeFirst: true,
            settleTimeout: 0,
            settlePollInterval: 0,
            settleStablePollCount: 0,
            applyPosition: { origin in
                operations.append("position:\(Int(origin.x)),\(Int(origin.y))")
                return .success
            },
            applySize: { size in
                operations.append("size:\(Int(size.width)),\(Int(size.height))")
                return .success
            },
            readFrame: { destinationFrame }
        )

        XCTAssertEqual(operations, [
            "size:3440,1335",
            "position:0,30",
            "size:3440,1335"
        ])
        XCTAssertTrue(result.positionApplied)
        XCTAssertEqual(result.finalSizeError, .success)
        XCTAssertEqual(result.postApplyFrame, destinationFrame)
    }

    func testApplyManagedFrameSkipsPositionWriteWhenPositionIsNotSettable() {
        let destinationFrame = CGRect(x: 0, y: 30, width: 1440, height: 840)
        var operations: [String] = []

        let result = MaximizeStrategy.applyManagedFrame(
            destinationFrame: destinationFrame,
            pid: 0,
            canSetPosition: false,
            settleTimeout: 0,
            settlePollInterval: 0,
            settleStablePollCount: 0,
            applyPosition: { _ in
                operations.append("position")
                return .success
            },
            applySize: { size in
                operations.append("size:\(Int(size.width)),\(Int(size.height))")
                return .success
            },
            readFrame: { destinationFrame }
        )

        XCTAssertEqual(operations, [
            "size:1440,840"
        ])
        XCTAssertFalse(result.positionApplied)
        XCTAssertEqual(result.finalSizeError, .success)
        XCTAssertEqual(result.notes, [AppStrings.maximizePositionNotSettable])
    }

    func testSettledFrameAfterApplyReturnsStableWrongFrameAfterAnimationStops() {
        let destinationFrame = CGRect(x: 0, y: 30, width: 3440, height: 1335)
        let settlingFrame = CGRect(x: 0, y: 62, width: 3120, height: 1260)
        let frames = [
            CGRect(x: 120, y: 90, width: 2800, height: 1100),
            CGRect(x: 60, y: 50, width: 3000, height: 1210),
            settlingFrame,
            settlingFrame,
            settlingFrame
        ]
        var iterator = frames[...]

        let settledFrame = MaximizeStrategy.settledFrameAfterApply(
            destinationFrame: destinationFrame,
            initialFrame: iterator.popFirst(),
            settleTimeout: 0.35,
            pollInterval: 0.05,
            stablePollCount: 2,
            readFrame: { iterator.popFirst() },
            sleep: { _ in }
        )

        XCTAssertEqual(settledFrame, settlingFrame)
    }

    func testSettledFrameAfterApplyReturnsDestinationWhenAnimationFinishesNaturally() {
        let destinationFrame = CGRect(x: 0, y: 30, width: 3440, height: 1335)
        let frames = [
            CGRect(x: 180, y: 120, width: 2600, height: 1080),
            CGRect(x: 80, y: 60, width: 3200, height: 1260),
            CGRect(x: 10, y: 35, width: 3430, height: 1330),
            destinationFrame
        ]
        var iterator = frames[...]

        let settledFrame = MaximizeStrategy.settledFrameAfterApply(
            destinationFrame: destinationFrame,
            initialFrame: iterator.popFirst(),
            settleTimeout: 0.35,
            pollInterval: 0.05,
            stablePollCount: 2,
            readFrame: { iterator.popFirst() },
            sleep: { _ in }
        )

        XCTAssertEqual(settledFrame, destinationFrame)
    }
}
