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

    func testMaximizedFrameLeavesTheGapAtEveryEdge() {
        let screen = ScreenDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 50, width: 1512, height: 900)
        )
        let full = ScreenHelpers.accessibilityRect(forVisibleFrame: screen.visibleFrame, in: [screen])

        XCTAssertEqual(MaximizeStrategy.maximizedFrame(on: screen, in: [screen], gap: 0), full)
        XCTAssertEqual(
            MaximizeStrategy.maximizedFrame(on: screen, in: [screen], gap: 16),
            CGRect(x: full.minX + 16, y: full.minY + 16, width: full.width - 32, height: full.height - 32)
        )
        // A gap with no room for a window counts as none.
        XCTAssertEqual(MaximizeStrategy.maximizedFrame(on: screen, in: [screen], gap: 400), full)
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

        let laptopWindowFrame = CGRect(x: 1120, y: -862, width: 1100, height: 720)
        XCTAssertEqual(
            MaximizeStrategy.targetRect(for: laptopWindowFrame, screens: screens),
            ScreenHelpers.accessibilityRect(forVisibleFrame: screens[1].visibleFrame, in: screens)
        )
    }

    func testTargetRectStaysOnLaptopWhenTheOtherDisplayIsAbove() {
        // The laptop is the main display; a wider display sits above it, sticking out to the left.
        let screens = [
            ScreenDescriptor(
                identifier: "laptop",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 72, width: 1512, height: 877)
            ),
            ScreenDescriptor(
                identifier: "above",
                frame: CGRect(x: -192, y: 982, width: 1920, height: 1080),
                visibleFrame: CGRect(x: -192, y: 982, width: 1920, height: 1080)
            )
        ]

        let laptopWindow = CGRect(x: 468, y: 134, width: 1025, height: 742)
        XCTAssertEqual(
            MaximizeStrategy.targetRect(for: laptopWindow, screens: screens),
            CGRect(x: 0, y: 33, width: 1512, height: 877)
        )

        let upperWindow = CGRect(x: 100, y: -900, width: 1000, height: 700)
        XCTAssertEqual(
            MaximizeStrategy.targetRect(for: upperWindow, screens: screens),
            CGRect(x: -192, y: -1080, width: 1920, height: 1080)
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
            CGRect(x: 0, y: 33, width: 1512, height: 949)
        )
        XCTAssertEqual(
            ScreenHelpers.accessibilityRect(forVisibleFrame: screens[1].visibleFrame, in: screens),
            CGRect(x: 1512, y: -110, width: 1728, height: 1060)
        )
    }

    func testDragRestoreFrameKeepsPointerAtTheSameShareOfTheTitleBar() {
        // Three quarters of the way along the maximized window.
        let destination = MaximizeStrategy.dragRestoreFrame(
            currentFrame: CGRect(x: 0, y: 25, width: 1440, height: 840),
            restoreFrame: CGRect(x: 100, y: 120, width: 900, height: 700),
            cursorLocation: CGPoint(x: 1080, y: 40)
        )

        XCTAssertEqual(destination, CGRect(x: 405, y: 25, width: 900, height: 700))
    }

    func testDragRestoreFrameFollowsAWindowTheDragAlreadyMoved() {
        // The drag moved the window 6 points right and 9 down before the restore.
        let destination = MaximizeStrategy.dragRestoreFrame(
            currentFrame: CGRect(x: 6, y: 34, width: 1440, height: 840),
            restoreFrame: CGRect(x: 100, y: 120, width: 900, height: 700),
            cursorLocation: CGPoint(x: 366, y: 49)
        )

        // A quarter of the way along, and still 15 points below the window's top.
        XCTAssertEqual(destination, CGRect(x: 141, y: 34, width: 900, height: 700))
    }

    func testAnimationStepsTowardTheDestinationAndStopsShortOfIt() {
        var clock: TimeInterval = 0
        var frames: [CGRect] = []
        let destination = CGRect(x: 0, y: 0, width: 1000, height: 800)

        MaximizeStrategy.animateFrame(
            from: CGRect(x: 200, y: 100, width: 600, height: 400),
            to: destination,
            duration: MaximizeStrategy.systemFillDuration,
            frameInterval: 0.02,
            now: { clock },
            sleep: { clock += $0 },
            apply: { frames.append($0) }
        )

        XCTAssertEqual(frames.count, 16)
        XCTAssertEqual(frames.map(\.width), frames.map(\.width).sorted())
        // A soft start, as the system's: the second step goes further than the first.
        XCTAssertGreaterThan(frames[1].width - frames[0].width, frames[0].width - 600)
        XCTAssertLessThan(frames.last!.width, destination.width)
    }

    func testAnimationFollowsTheSystemsMeasuredFill() {
        // Shares of the way measured on a window filled by the system, 41 to 224 ms
        // after it started to move.
        for (time, measured) in [(0.041, 0.330), (0.082, 0.676), (0.123, 0.862), (0.174, 0.955), (0.224, 0.986)] {
            XCTAssertEqual(MaximizeStrategy.fillAnimationProgress(at: time), measured, accuracy: 0.02)
        }
        XCTAssertGreaterThan(MaximizeStrategy.fillAnimationProgress(at: 0.33), 0.998)
    }

    func testAShorterAnimationRunsTheSameCurveFaster() {
        var clock: TimeInterval = 0
        var widths: [CGFloat] = []
        MaximizeStrategy.animateFrame(
            from: CGRect(x: 0, y: 0, width: 0, height: 100),
            to: CGRect(x: 0, y: 0, width: 1000, height: 100),
            duration: MaximizeStrategy.systemFillDuration / 2,
            frameInterval: 0.0205,
            now: { clock },
            sleep: { clock += $0 },
            apply: { widths.append($0.width) }
        )
        // Half way through the time, where the system's curve is at 0.041 s: 33 %.
        XCTAssertEqual(widths.first ?? 0, 330, accuracy: 25)
        XCTAssertGreaterThan(widths.last ?? 0, 990)
    }

    func testDragRestoreAnimationShrinksEvenlyTowardAMovingPointerAndThenFollowsIt() {
        var clock: TimeInterval = 0
        var pointer = CGPoint(x: 1000, y: 47)
        var frames: [CGRect] = []
        var positions: [CGPoint] = []
        var framesWaitedFor = 0

        MaximizeStrategy.animateDragRestore(
            from: CGSize(width: 1500, height: 900),
            to: CGSize(width: 700, height: 500),
            pointerOffset: CGPoint(x: 175, y: 14),
            duration: 0.33,
            now: { clock },
            // A display at 120 frames a second.
            waitForFrame: {
                clock += 1.0 / 120.0
                framesWaitedFor += 1
            },
            pointerLocation: {
                // The pointer moves until 0.5 s, then stays for a while.
                if clock < 0.5 {
                    pointer.x -= 5
                    pointer.y += 3
                }
                return pointer
            },
            // The button comes up after 0.7 s.
            isReleased: { clock >= 0.7 },
            applyFrame: { frame in
                XCTAssertTrue(positions.isEmpty, "The size changed after the animation")
                frames.append(frame)
                // The pointer is a quarter of the way along at every step, and at the
                // same height in the window.
                XCTAssertEqual((pointer.x - frame.minX) / frame.width, 0.25, accuracy: 0.002)
                XCTAssertEqual(pointer.y - frame.minY, 14)
            },
            applyPosition: { position in
                positions.append(position)
                XCTAssertEqual(position, CGPoint(x: pointer.x - 175, y: pointer.y - 14))
            }
        )

        // One step for each frame of the display, over the length of the animation.
        XCTAssertEqual(frames.count, 40, accuracy: 2)
        XCTAssertEqual(frames.last?.size, CGSize(width: 700, height: 500))
        // Both sides come in: the left edge moves right while the right edge moves left.
        XCTAssertGreaterThan(frames[3].minX - frames[0].minX, 0)
        XCTAssertLessThan(frames[3].maxX - frames[0].maxX, 0)
        // After the animation the window follows the pointer, and nothing is written
        // for a frame in which the pointer stayed.
        XCTAssertEqual(positions.count, 20, accuracy: 2)
        XCTAssertGreaterThan(framesWaitedFor, frames.count + positions.count + 10)
    }

    func testAnimationOfASlowWindowTakesFewerStepsNotLonger() {
        var clock: TimeInterval = 0
        var steps = 0

        MaximizeStrategy.animateFrame(
            from: CGRect(x: 200, y: 100, width: 600, height: 400),
            to: CGRect(x: 0, y: 0, width: 1000, height: 800),
            duration: 0.1,
            frameInterval: 0.02,
            now: { clock },
            sleep: { clock += $0 },
            apply: { _ in
                steps += 1
                clock += 0.045
            }
        )

        XCTAssertEqual(steps, 2)
        XCTAssertLessThan(clock, 0.15)
    }

    func testAnimationSkipsAWindowAlreadyInPlace() {
        var steps = 0
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        MaximizeStrategy.animateFrame(from: frame, to: frame, duration: 0.1, apply: { _ in steps += 1 })

        XCTAssertEqual(steps, 0)
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
            lastManagedMaximizeFrame: CGRect(x: 1440, y: -192, width: 1728, height: 1060)
        )

        let resolution = MaximizeStrategy.resolvedRestoreFrame(
            currentFrame: CGRect(x: 1440, y: -192, width: 1728, height: 1060),
            storedState: storedState,
            screens: screens
        )

        XCTAssertEqual(resolution?.frame, CGRect(x: 2268, y: 168, width: 900, height: 700))
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
            restoreFrame: CGRect(x: 1100, y: -900, width: 1200, height: 700),
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

    func testResolvedRestoreFrameUsesDragRestoreDestination() {
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

        XCTAssertEqual(resolution?.frame, CGRect(x: 239, y: 35, width: 1200, height: 700))
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
