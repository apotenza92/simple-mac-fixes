import CoreGraphics
import XCTest
@testable import MaximizeFeature

final class DragFollowerTests: XCTestCase {
    private final class Window: @unchecked Sendable {
        var origin = CGPoint(x: 200, y: 33)
        var writes: [CGPoint] = []
        var clock: TimeInterval = 0
    }

    private func follower(for window: Window) -> DragFollower {
        DragFollower(
            pointerOffset: CGPoint(x: 300, y: 14),
            restDelay: 0.02,
            now: { window.clock },
            currentOrigin: { window.origin },
            write: {
                window.origin = $0
                window.writes.append($0)
            }
        )
    }

    private func settle(_ follower: DragFollower, for interval: TimeInterval = 0.08) {
        follower.waitUntilIdle()
        Thread.sleep(forTimeInterval: interval)
        follower.waitUntilIdle()
    }

    func testAWindowTheSystemMovesIsNotWrittenWhileThePointerMoves() {
        let window = Window()
        let follower = follower(for: window)

        // The system keeps the window 5 points off, and moves it with the pointer.
        for step in 1...30 {
            window.clock += 0.016
            window.origin = CGPoint(x: 205 + CGFloat(step) * 4, y: 33)
            follower.pointerMoved(to: CGPoint(x: 500 + CGFloat(step) * 4, y: 47))
            follower.waitUntilIdle()
        }

        XCTAssertTrue(window.writes.isEmpty)
    }

    func testAWindowFarOffAMovingPointerIsPutBackOnceInAWhile() {
        let window = Window()
        let follower = follower(for: window)

        // The system keeps the window 160 points off, and moves it with the pointer,
        // 4 points every 16 ms: far more than a window that trails the pointer.
        for step in 1...30 {
            window.clock += 0.016
            if window.writes.isEmpty {
                window.origin = CGPoint(x: 360 + CGFloat(step) * 4, y: 33)
            } else {
                window.origin.x += 4
            }
            follower.pointerMoved(to: CGPoint(x: 500 + CGFloat(step) * 4, y: 47))
            follower.waitUntilIdle()
        }

        XCTAssertEqual(window.writes.count, 1)
        XCTAssertEqual(window.origin, CGPoint(x: 320, y: 33))
    }

    func testAWindowThatTrailsAFastPointerIsLeftAlone() {
        let window = Window()
        let follower = follower(for: window)

        // 40 points every 16 ms, and the window is two moves behind.
        for step in 1...30 {
            window.clock += 0.016
            window.origin = CGPoint(x: 200 + CGFloat(step - 2) * 40, y: 33)
            follower.pointerMoved(to: CGPoint(x: 500 + CGFloat(step) * 40, y: 47))
            follower.waitUntilIdle()
        }

        XCTAssertTrue(window.writes.isEmpty)
    }

    func testAWindowOffThePointerIsPutBackWhenThePointerRests() {
        let window = Window()
        let follower = follower(for: window)

        window.origin = CGPoint(x: 265, y: 80)
        follower.pointerMoved(to: CGPoint(x: 560, y: 90))
        settle(follower)

        XCTAssertEqual(window.writes, [CGPoint(x: 260, y: 76)])
    }

    func testAWindowUnderThePointerIsLeftAloneWhenThePointerRests() {
        let window = Window()
        let follower = follower(for: window)

        window.origin = CGPoint(x: 260.5, y: 76)
        follower.pointerMoved(to: CGPoint(x: 560, y: 90))
        settle(follower)

        XCTAssertTrue(window.writes.isEmpty)
    }

    func testAWindowThatStoppedFollowingIsMovedWithThePointer() {
        let window = Window()
        let follower = follower(for: window)

        // The window stays where it is for half a second of travel.
        for step in 1...30 {
            window.clock += 0.016
            follower.pointerMoved(to: CGPoint(x: 500 + CGFloat(step) * 4, y: 47))
            follower.waitUntilIdle()
        }

        XCTAssertEqual(window.origin, CGPoint(x: 320, y: 33))
        XCTAssertGreaterThan(window.writes.count, 5)
    }

    func testAWindowThatMovesAgainByItselfIsLeftToTheSystem() {
        let window = Window()
        let follower = follower(for: window)

        for step in 1...30 {
            window.clock += 0.016
            follower.pointerMoved(to: CGPoint(x: 500 + CGFloat(step) * 4, y: 47))
            follower.waitUntilIdle()
        }
        let writesWhileStuck = window.writes.count

        for step in 31...40 {
            window.clock += 0.016
            window.origin = CGPoint(x: 207 + CGFloat(step) * 4, y: 33)
            follower.pointerMoved(to: CGPoint(x: 500 + CGFloat(step) * 4, y: 47))
            follower.waitUntilIdle()
        }

        XCTAssertEqual(window.writes.count, writesWhileStuck)
    }

    func testTheReleaseChecksThePlaceOnce() {
        let window = Window()
        let follower = follower(for: window)

        window.origin = CGPoint(x: 265, y: 80)
        follower.finish(at: CGPoint(x: 560, y: 90))
        follower.pointerMoved(to: CGPoint(x: 900, y: 500))
        settle(follower)

        XCTAssertEqual(window.writes, [CGPoint(x: 260, y: 76)])
    }
}
