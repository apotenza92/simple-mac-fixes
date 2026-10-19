import CoreGraphics
import Foundation

/// Asks the app under the pointer about a click, but never holds the click for
/// longer than `deadline`. A slow answer is dropped and the click goes through
/// untouched; while an app is still busy with an earlier question, clicks go
/// through at once rather than queueing behind it.
final class BoundedContextResolver: GreenButtonContextResolving, TitleBarContextResolving, @unchecked Sendable {
    static let defaultDeadline: TimeInterval = 0.15

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
        bounded { [base] in base.resolveGreenButtonClick(at: location) }
    }

    func resolveTitleBarInteraction(at location: CGPoint) -> TitleBarInteractionContext? {
        bounded { [base] in base.resolveTitleBarInteraction(at: location) }
    }

    private func bounded<T>(_ work: @escaping () -> T?) -> T? {
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
        guard done.wait(timeout: .now() + deadline) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return box.value
    }
}
