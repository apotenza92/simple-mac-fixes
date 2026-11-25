import CoreGraphics
import Foundation

/// Asks the app under the pointer about a click, but never holds the click for
/// longer than `deadline`. A slow answer is dropped and the click goes through
/// untouched; while an app is still busy with an earlier question, clicks go
/// through at once rather than queueing behind it.
final class BoundedContextResolver: GreenButtonContextResolving, TitleBarContextResolving, @unchecked Sendable {
    static let defaultDeadline: TimeInterval = 0.15
    /// A click on a green button waits for the answer: one let through goes to the
    /// system, which opens full screen (seen in GitHub Desktop just after it opened).
    static let greenButtonDeadline: TimeInterval = 0.3
    /// A press on a window this feature maximized: the window holds still for the
    /// first points of a drag anyway. Mail's answer took 141 to 155 ms, and at 0.15 s
    /// 3 of 4 drags were let through and moved the window at its maximized size.
    static let maximizedWindowDeadline: TimeInterval = 0.4


    private final class Box<T>: @unchecked Sendable { var value: T? }

    private let base: GreenButtonContextResolving & TitleBarContextResolving
    private let deadline: TimeInterval
    private let queue = DispatchQueue(label: "Macsimize.ContextLookup")
    private let lock = NSLock()
    private var busy = false

    init(base: GreenButtonContextResolving & TitleBarContextResolving,
         deadline: TimeInterval = BoundedContextResolver.defaultDeadline) {
        self.base = base
        self.deadline = deadline
    }

    func resolveGreenButtonClick(at location: CGPoint) -> ClickedWindowContext? {
        bounded(within: max(deadline, Self.greenButtonDeadline)) { [base] in base.resolveGreenButtonClick(at: location) }
    }

    func resolveTitleBarInteraction(at location: CGPoint, isDoubleClick: Bool) -> TitleBarInteractionContext? {
        resolveTitleBarInteraction(at: location, isDoubleClick: isDoubleClick, waitsLonger: false)
    }

    /// `waitsLonger` for a title-bar double-click and for a press on a window this
    /// feature maximized.
    func resolveTitleBarInteraction(at location: CGPoint, isDoubleClick: Bool, waitsLonger: Bool) -> TitleBarInteractionContext? {
        let limit = waitsLonger ? max(deadline, Self.maximizedWindowDeadline) : deadline
        return bounded(within: limit) { [base] in base.resolveTitleBarInteraction(at: location, isDoubleClick: isDoubleClick) }
    }

    private func bounded<T>(within limit: TimeInterval, _ work: @escaping () -> T?) -> T? {
        lock.lock()
        guard !busy else {
            lock.unlock()
            return nil
        }
        busy = true
        lock.unlock()

        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            let value = work()
            lock.lock()
            box.value = value
            busy = false
            lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return box.value
    }
}
