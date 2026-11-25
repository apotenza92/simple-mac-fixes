import XCTest
@testable import MaximizeFeature

final class DisplayClockTests: XCTestCase {
    private let period = 1.0 / 120.0

    func testWritesGoOutTwoMillisecondsAfterTheNextFrame() {
        let clock = DisplayClock()
        clock.recordFrame(at: 10.0, period: period)
        XCTAssertEqual(clock.timeToNextFrame(from: 10.001, offset: DisplayClock.writeOffset) ?? -1,
                       0.001, accuracy: 0.0001)
        XCTAssertEqual(clock.timeToNextFrame(from: 10.003, offset: DisplayClock.writeOffset) ?? -1,
                       period - 0.001, accuracy: 0.0001)
    }

    func testAStepThatTookAFrameGoesOnAtOnceAndOnlyOnce() {
        let clock = DisplayClock()
        clock.recordFrame(at: ProcessInfo.processInfo.systemUptime, period: period)
        clock.step { Thread.sleep(forTimeInterval: 0.012) }
        var start = Date()
        clock.waitForNextFrame()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.002)
        // The next wait waits again, so a loop that writes nothing does not spin.
        clock.recordFrame(at: ProcessInfo.processInfo.systemUptime, period: period)
        start = Date()
        clock.waitForNextFrame()
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.001)
    }
}
