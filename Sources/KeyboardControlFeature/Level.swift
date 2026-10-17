import Foundation

public struct Level: Equatable, Sendable {
    public static let defaultStep = 6

    public private(set) var percent: Int
    public private(set) var isMuted: Bool

    public init(percent: Int = 50, isMuted: Bool = false) {
        self.percent = Self.clamp(percent)
        self.isMuted = isMuted
    }

    public var gain: Float {
        guard !isMuted else { return 0 }
        let scalar = Float(percent) / 100
        return scalar * scalar
    }

    public mutating func set(_ value: Int) {
        percent = Self.clamp(value)
        isMuted = false
    }

    public mutating func nudge(_ delta: Int) {
        percent = Self.clamp(percent + delta)
        isMuted = false
    }

    public mutating func toggleMute() {
        isMuted.toggle()
    }

    public static func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}
