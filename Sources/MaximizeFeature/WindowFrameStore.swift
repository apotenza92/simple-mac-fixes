import CoreGraphics
import Foundation

struct StoredWindowFrameState: Equatable {
    let restoreFrame: CGRect
    let lastManagedMaximizeFrame: CGRect?
}

/// Each maximized window's size before, so a second click or a drag puts it back.
/// With `defaults` it's kept there too, so it lasts through the app restarting or
/// updating while the windows stay open.
final class WindowFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String: StoredWindowFrameState] = [:] {
        didSet { save() }
    }
    private let defaults: UserDefaults?
    static let defaultsKey = "maximize.windowFrames"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        frames = Self.load(from: defaults)
    }

    /// Windows whose app has since quit are left behind.
    private static func load(from defaults: UserDefaults?) -> [String: StoredWindowFrameState] {
        guard let saved = defaults?.dictionary(forKey: defaultsKey) as? [String: [Double]] else { return [:] }
        var frames: [String: StoredWindowFrameState] = [:]
        for (identifier, numbers) in saved where numbers.count == 4 || numbers.count == 8 {
            guard let pid = pid(in: identifier), kill(pid, 0) == 0 else { continue }
            let restore = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            let maximized = numbers.count == 8 ? CGRect(x: numbers[4], y: numbers[5], width: numbers[6], height: numbers[7]) : nil
            frames[identifier] = StoredWindowFrameState(restoreFrame: restore, lastManagedMaximizeFrame: maximized)
        }
        return frames
    }

    private func save() {
        guard let defaults else { return }
        let numbers = frames.mapValues { state -> [Double] in
            var values = [state.restoreFrame.minX, state.restoreFrame.minY, state.restoreFrame.width, state.restoreFrame.height]
            if let maximized = state.lastManagedMaximizeFrame {
                values += [maximized.minX, maximized.minY, maximized.width, maximized.height]
            }
            return values.map(Double.init)
        }
        defaults.set(numbers, forKey: Self.defaultsKey)
    }

    /// Identifiers start "pid:<number>-".
    static func pid(in identifier: String) -> pid_t? {
        guard identifier.hasPrefix("pid:"), let end = identifier.firstIndex(of: "-") else { return nil }
        return pid_t(identifier[identifier.index(identifier.startIndex, offsetBy: 4)..<end])
    }

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

    /// Whether a window of `pid` that this feature maximized is at `bounds`, from the
    /// window server's list alone, with no question to the app.
    /// It runs for a press near the top of a window, so it reads the store in place.
    func hasMaximizedWindow(pid: pid_t, at bounds: CGRect) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.contains { identifier, state in
            guard let maximized = state.lastManagedMaximizeFrame,
                  MaximizeStrategy.framesNearlyEqual(maximized, bounds) else { return false }
            return Self.pid(in: identifier) == pid
        }
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
