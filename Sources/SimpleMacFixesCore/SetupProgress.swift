import Foundation

/// Only an explicit Finish completes setup; permission requests are independent.
public final class SetupProgress {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var isComplete: Bool { defaults.bool(forKey: "hasCompletedSetup") }
    public var step: Int {
        get { min(2, max(0, defaults.integer(forKey: "setupStep"))) }
        set { defaults.set(min(2, max(0, newValue)), forKey: "setupStep") }
    }
    public func beginAgain() {
        defaults.set(false, forKey: "hasCompletedSetup")
        step = 0
    }
    public func finish() { defaults.set(true, forKey: "hasCompletedSetup") }
}
