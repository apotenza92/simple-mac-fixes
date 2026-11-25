import ApplicationServices
import CoreGraphics
import Foundation

/// Puts a window back under the pointer during a drag that restored its size.
///
/// The system moves a dragged window itself, and a position written during the drag
/// does not always hold. Measured on a plain AppKit window: the window ended up to
/// 6 points from where it was put, and in 3 of 12 drags it stopped following the
/// pointer at all (in T3 Code one drag ended 242 points off).
///
/// Writing the position on every move of the drag fixed the end position but fought
/// the system's own moves while the pointer was in motion: in T3 Code the window
/// jumped about. So the window is written only where nothing else moves it:
/// - when the pointer rests, and on release: the window is not where the pointer
///   needs it, and the system is not moving it then.
/// - while the pointer moves, when the window is further off than a window that only
///   trails the pointer can be: more than the distance the pointer covers in
///   `trailTime`, and more than `trailDistance`. Seen after the window server stalled
///   for half a second during the restore: the window then followed 162 points off
///   until the pointer rested. At most one such write in `correctionInterval`.
/// - on every move, but only after the window stayed in one place while the pointer
///   travelled (`stuckAfter`, `stuckTravel`): the system stopped moving it. A window
///   that moves again by itself ends this.
///
/// Moves arrive on the event tap's thread and only record the newest pointer
/// position. Checks and writes run on a queue of their own.
final class DragFollower: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Macsimize.DragFollower", qos: .userInteractive)
    private let pointerOffset: CGPoint
    private let currentOrigin: () -> CGPoint?
    private let write: (CGPoint) -> Void
    private let now: () -> TimeInterval
    private let tolerance: CGFloat
    private let restDelay: TimeInterval
    private let stuckAfter: TimeInterval
    private let stuckTravel: CGFloat
    private let trailTime: TimeInterval
    private let trailDistance: CGFloat
    private let correctionInterval: TimeInterval

    // Guarded by `lock`.
    private var newestLocation: CGPoint?
    private var isFollowing = false
    private var moveCount = 0
    private var isFinished = false

    // Used on `queue` only.
    private var isStuck = false
    private var lastWritten: CGPoint?
    private var seenOrigin: CGPoint?
    private var seenSince: TimeInterval = 0
    private var pointerWhenSeen = CGPoint.zero
    private var lastMove: (location: CGPoint, time: TimeInterval)?
    private var speed: CGFloat = 0
    private var lastCorrection: TimeInterval = -.infinity

    /// `pointerOffset` is where the pointer sits in the window, from its top left.
    init(
        pointerOffset: CGPoint,
        tolerance: CGFloat = 1,
        restDelay: TimeInterval = 0.12,
        stuckAfter: TimeInterval = 0.3,
        stuckTravel: CGFloat = 24,
        trailTime: TimeInterval = 0.2,
        trailDistance: CGFloat = 12,
        correctionInterval: TimeInterval = 0.15,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        currentOrigin: @escaping () -> CGPoint?,
        write: @escaping (CGPoint) -> Void
    ) {
        self.pointerOffset = pointerOffset
        self.tolerance = tolerance
        self.restDelay = restDelay
        self.stuckAfter = stuckAfter
        self.stuckTravel = stuckTravel
        self.trailTime = trailTime
        self.trailDistance = trailDistance
        self.correctionInterval = correctionInterval
        self.now = now
        self.currentOrigin = currentOrigin
        self.write = write
    }

    convenience init(context: ClickedWindowContext, pointerOffset: CGPoint) {
        let window = context.windowElement
        let windowNumber = context.windowNumber
        self.init(
            pointerOffset: pointerOffset,
            currentOrigin: { Self.origin(ofWindow: windowNumber, element: window) },
            write: { AXHelpers.set(position: $0, on: window) }
        )
    }

    func pointerMoved(to location: CGPoint) {
        noteLocation(location, finished: false)
    }

    /// The button came up at `location`: one last check once the system let go.
    func finish(at location: CGPoint) {
        noteLocation(location, finished: true)
    }

    private func noteLocation(_ location: CGPoint, finished: Bool) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = finished
        newestLocation = location
        moveCount += 1
        let count = moveCount
        let start = !isFollowing
        if start {
            isFollowing = true
        }
        lock.unlock()

        if start {
            queue.async { [self] in follow() }
        }
        queue.asyncAfter(deadline: .now() + (finished ? restDelay / 2 : restDelay)) { [self] in
            lock.lock()
            let rested = moveCount == count
            lock.unlock()
            if rested {
                place(forPointerAt: location)
            }
        }
    }

    /// Waits for the checks in progress, so a test can read the result.
    func waitUntilIdle() {
        queue.sync {}
    }

    private func follow() {
        while true {
            lock.lock()
            guard let location = newestLocation else {
                isFollowing = false
                lock.unlock()
                return
            }
            newestLocation = nil
            lock.unlock()

            guard let origin = currentOrigin() else {
                continue
            }
            let time = now()

            if isStuck {
                if let lastWritten, !Self.isNear(origin, lastWritten, tolerance: tolerance) {
                    // Something else moved the window: the system has it again.
                    isStuck = false
                } else {
                    writeIfNeeded(origin: origin, pointer: location)
                    continue
                }
            }

            // Points a second, taking the faster of this move and the one before, so
            // one slow move in a fast drag does not look like a pointer at rest.
            var speedNow: CGFloat?
            if let lastMove, time > lastMove.time {
                speedNow = hypot(location.x - lastMove.location.x, location.y - lastMove.location.y) / (time - lastMove.time)
            }
            lastMove = (location, time)
            if let speedNow {
                let allowed = max(trailDistance, max(speed, speedNow) * trailTime)
                speed = speedNow
                let target = Self.origin(forPointerAt: location, pointerOffset: pointerOffset)
                if hypot(origin.x - target.x, origin.y - target.y) > allowed, time - lastCorrection >= correctionInterval {
                    lastCorrection = time
                    writeIfNeeded(origin: origin, pointer: location)
                }
            }

            // A window that is where it was, or where this put it, did not move by itself.
            let unmoved = seenOrigin.map { Self.isNear(origin, $0, tolerance: 0.5) } ?? false
                || lastWritten.map { Self.isNear(origin, $0, tolerance: tolerance) } ?? false
            if unmoved, seenOrigin != nil {
                let travel = hypot(location.x - pointerWhenSeen.x, location.y - pointerWhenSeen.y)
                if time - seenSince >= stuckAfter, travel >= stuckTravel {
                    isStuck = true
                    writeIfNeeded(origin: origin, pointer: location)
                }
            } else {
                seenOrigin = origin
                seenSince = time
                pointerWhenSeen = location
            }
        }
    }

    private func place(forPointerAt location: CGPoint) {
        guard let origin = currentOrigin() else {
            return
        }
        writeIfNeeded(origin: origin, pointer: location)
        seenOrigin = nil
    }

    private func writeIfNeeded(origin: CGPoint, pointer: CGPoint) {
        let target = Self.origin(forPointerAt: pointer, pointerOffset: pointerOffset)
        guard !Self.isNear(origin, target, tolerance: tolerance) else {
            return
        }
        write(target)
        lastWritten = target
    }

    private static func isNear(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    static func origin(forPointerAt location: CGPoint, pointerOffset: CGPoint) -> CGPoint {
        CGPoint(x: (location.x - pointerOffset.x).rounded(), y: (location.y - pointerOffset.y).rounded())
    }

    /// The window server's own answer where it has one: the app's can be a tenth of a
    /// second old while its window is dragged.
    static func origin(ofWindow windowNumber: Int?, element: AXUIElement) -> CGPoint? {
        windowNumber.flatMap { serverOrigin(ofWindow: $0) } ?? AXHelpers.cgRect(of: element)?.origin
    }

    private static func serverOrigin(ofWindow windowNumber: Int) -> CGPoint? {
        guard let entries = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let bounds = entries.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else {
            return nil
        }
        return rect.origin
    }
}
