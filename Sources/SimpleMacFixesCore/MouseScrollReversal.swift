import AppKit
import CoreGraphics

/// Makes wheel mice scroll the traditional way while trackpads and the
/// Magic Mouse keep the System Settings direction.
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
        guard MouseScrollReversal.shouldReverse(source: source, naturalScrollingEnabled: natural) else { return }
        for (delta, fixed, point) in axes {
            // Read every representation before writing: setting the line delta
            // makes CoreGraphics recompute the others.
            let lines = event.getIntegerValueField(delta)
            let fixedLines = event.getDoubleValueField(fixed)
            let points = event.getIntegerValueField(point)
            event.setIntegerValueField(delta, value: -lines)
            event.setDoubleValueField(fixed, value: -fixedLines)
            event.setIntegerValueField(point, value: -points)
        }
    }
}
