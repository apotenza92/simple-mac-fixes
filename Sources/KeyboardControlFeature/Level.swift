import Foundation

public struct Level: Equatable, Sendable {
    /// Like the system, a key press moves one of 16 steps and a fine press a quarter step.
    public static let steps = 16
    public static let fineSteps = 64

    public private(set) var percent: Double
    public private(set) var isMuted: Bool

    public init(percent: Double = 50, isMuted: Bool = false) {
        self.percent = Self.clamp(percent)
        self.isMuted = isMuted
    }

    public var gain: Float {
        guard !isMuted else { return 0 }
        let scalar = Float(percent / 100)
        return scalar * scalar
    }

    public mutating func set(_ value: Double) {
        percent = Self.clamp(value)
        isMuted = false
    }

    public mutating func step(up: Bool, fine: Bool) {
        percent = Self.stepped(percent, up: up, fine: fine)
        isMuted = false
    }

    public mutating func toggleMute() {
        isMuted.toggle()
    }

    /// The next step mark above or below `percent`, so a level set some other way
    /// joins the system's steps. A hundredth of a step of slack keeps a value read back
    /// as 62.4999 from counting as below 62.5.
    public static func stepped(_ percent: Double, up: Bool, fine: Bool) -> Double {
        let size = 100 / Double(fine ? fineSteps : steps)
        let position = percent / size
        let mark = up ? (position + 0.01).rounded(.down) + 1 : (position - 0.01).rounded(.up) - 1
        return clamp(mark * size)
    }

    public static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
