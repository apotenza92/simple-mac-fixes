import AppKit
import CoreGraphics

/// Makes wheel mice scroll like Windows: the traditional direction and three
/// lines per notch. Trackpads and the Magic Mouse keep the System Settings direction.
public enum MouseScrollReversal {
    public enum Source: Equatable {
        /// A notched or free-spinning wheel: no gesture phases.
        case wheel
        /// A trackpad or Magic Mouse: every event carries a gesture or momentum phase.
        case gesture
    }

    public static func source(scrollPhase: Int64, momentumPhase: Int64) -> Source {
        scrollPhase == 0 && momentumPhase == 0 ? .wheel : .gesture
    }

    /// Natural scrolling is one system-wide setting, so a wheel only needs
    /// flipping while it is on.
    public static func shouldReverse(source: Source, naturalScrollingEnabled: Bool) -> Bool {
        source == .wheel && naturalScrollingEnabled
    }

    /// Windows scrolls three lines per wheel notch.
    public static let linesPerNotch: Int64 = 3
    /// macOS turns one line into ten points for line-based scrolling.
    public static let pointsPerLine: Int64 = 10

    /// One notch arrives as one event, sped up by macOS scroll acceleration.
    /// Only its direction is kept, so every notch moves the same three lines.
    public static func lines(forNotch lines: Int64, fixedLines: Double) -> Int64 {
        let direction = fixedLines != 0 ? fixedLines.sign == .minus ? -1 : 1 : lines.signum()
        return direction * linesPerNotch
    }
}

public final class MouseScrollReversalFeature {
    private lazy var tap = EventTap(types: [.scrollWheel]) { _, event in
        Self.process(event)
        return true
    }

    public init() {}

    public var isRunning: Bool { tap.isRunning }
    @discardableResult public func start() -> Bool { tap.start() }
    public func stop() { tap.stop() }

    private static let axes: [(CGEventField, CGEventField, CGEventField)] = [
        (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
        (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
    ]

    private static func process(_ event: CGEvent) {
        let source = MouseScrollReversal.source(
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        )
        guard source == .wheel else { return }
        let natural = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        let sign: Int64 = MouseScrollReversal.shouldReverse(source: source, naturalScrollingEnabled: natural) ? -1 : 1
        // High-resolution wheels send continuous pixel scrolling; those keep their
        // distance and only change direction.
        let notched = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
        guard notched || sign == -1 else { return }
        for (delta, fixed, point) in axes {
            // Read every representation before writing, and write points last:
            // setting the line delta makes CoreGraphics recompute the others.
            let lines = event.getIntegerValueField(delta)
            let fixedLines = event.getDoubleValueField(fixed)
            let points = event.getIntegerValueField(point)
            guard lines != 0 || fixedLines != 0 || points != 0 else { continue }
            if notched {
                let step = sign * MouseScrollReversal.lines(forNotch: lines, fixedLines: fixedLines)
                event.setIntegerValueField(delta, value: step)
                event.setDoubleValueField(fixed, value: Double(step))
                event.setIntegerValueField(point, value: step * MouseScrollReversal.pointsPerLine)
            } else {
                event.setIntegerValueField(delta, value: -lines)
                event.setDoubleValueField(fixed, value: -fixedLines)
                event.setIntegerValueField(point, value: -points)
            }
        }
    }
}
