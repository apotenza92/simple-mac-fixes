import CoreGraphics
import CoreVideo
import Foundation

/// Tells when the display shows its next frame, so that a window's size and position
/// can be written early in the same frame.
final class DisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var link: CVDisplayLink?
    private var lastFrame: TimeInterval = 0
    private var period: TimeInterval = 0
    /// How long the last step's writes took (`step`), until a wait uses it.
    private var lastStep: TimeInterval = 0

    /// How long after a frame starts the writes go out. Filmed at 0, 1, 2, 4 and
    /// 6 ms: at 2 ms the fewest frames showed a size with the position of the step before.
    static let writeOffset: TimeInterval = 0.002

    func start(displayAt point: CGPoint) {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        var found: CGDirectDisplayID = 0
        if CGGetDisplaysWithPoint(point, 1, &found, &count) == .success, count > 0 {
            display = found
        }
        start(display: display)
    }

    /// Runs one step's writes, and keeps how long they took for the next wait.
    func step(_ writes: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        writes()
        let took = ProcessInfo.processInfo.systemUptime - start
        lock.lock()
        lastStep = took
        lock.unlock()
    }

    /// Waits until the writes for the next frame can go out. Before the display
    /// reported a frame, for a 120th of a second.
    ///
    /// Not after a step that took a frame or longer: the app took that long to lay out
    /// the new size, its next frame went by meanwhile, and waiting lost another one.
    /// Measured on the window server's own frames: Finder took 17 ms for half its
    /// size writes, and steps came 34 ms apart (Apple's fill, 23 ms). Each step's
    /// place on the curve comes from the clock, so the timing of the motion holds.
    func waitForNextFrame() {
        lock.lock()
        let late = period > 0.001 && lastStep >= period
        lastStep = 0
        lock.unlock()
        if late {
            return
        }
        let wait = timeToNextFrame(from: ProcessInfo.processInfo.systemUptime, offset: Self.writeOffset)
        Thread.sleep(forTimeInterval: wait ?? 1.0 / 120.0)
    }

    private func start(display: CGDirectDisplayID) {
        var made: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(display, &made) == kCVReturnSuccess, let made else {
            return
        }
        let frequency = CVGetHostClockFrequency()
        CVDisplayLinkSetOutputHandler(made) { [weak self] _, _, output, _, _ in
            guard let self else {
                return kCVReturnSuccess
            }
            let time = Double(output.pointee.hostTime) / frequency
            let period = output.pointee.videoTimeScale > 0
                ? Double(output.pointee.videoRefreshPeriod) / Double(output.pointee.videoTimeScale)
                : 0
            self.recordFrame(at: time, period: period)
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(made)
        lock.lock()
        link = made
        lock.unlock()
    }

    /// A frame the display started at `time`, `period` after the one before.
    func recordFrame(at time: TimeInterval, period: TimeInterval) {
        lock.lock()
        lastFrame = time
        self.period = period
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let link = self.link
        self.link = nil
        lastFrame = 0
        lock.unlock()
        if let link {
            CVDisplayLinkStop(link)
        }
    }

    /// How long from `now` until `offset` after the start of the next frame. Nil
    /// until the display reported a frame.
    func timeToNextFrame(from now: TimeInterval, offset: TimeInterval) -> TimeInterval? {
        lock.lock()
        let lastFrame = self.lastFrame
        let period = self.period
        lock.unlock()
        guard lastFrame > 0, period > 0.001 else {
            return nil
        }
        let sinceFrame = (now - lastFrame - offset).truncatingRemainder(dividingBy: period)
        let phase = sinceFrame < 0 ? sinceFrame + period : sinceFrame
        return period - phase
    }
}
