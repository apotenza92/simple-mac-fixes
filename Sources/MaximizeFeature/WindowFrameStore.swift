import CoreGraphics
import Foundation

struct StoredWindowFrameState: Equatable {
    let restoreFrame: CGRect
    let lastManagedMaximizeFrame: CGRect?
}

final class WindowFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String: StoredWindowFrameState] = [:]

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty
    }

    func store(frame: CGRect, for identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        frames[identifier] = StoredWindowFrameState(restoreFrame: frame, lastManagedMaximizeFrame: nil)
    }

    func storeTransition(originalFrame: CGRect, maximizedFrame: CGRect, for identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        frames[identifier] = StoredWindowFrameState(restoreFrame: originalFrame, lastManagedMaximizeFrame: maximizedFrame)
    }

    func storedFrame(for identifier: String) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return frames[identifier]?.restoreFrame
    }

    func storedState(for identifier: String) -> StoredWindowFrameState? {
        lock.lock()
        defer { lock.unlock() }
        return frames[identifier]
    }

    func managedStatesSnapshot() -> [String: StoredWindowFrameState] {
        lock.lock()
        defer { lock.unlock() }
        return frames.filter { $0.value.lastManagedMaximizeFrame != nil }
    }

    func managedWindowIdentifiers() -> Set<String> {
        Set(managedStatesSnapshot().keys)
    }

    @discardableResult
    func popStoredFrame(for identifier: String) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return frames.removeValue(forKey: identifier)?.restoreFrame
    }

    func removeStoredFrame(for identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        frames.removeValue(forKey: identifier)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
    }
}
