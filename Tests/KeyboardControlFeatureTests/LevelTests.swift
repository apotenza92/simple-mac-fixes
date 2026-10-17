import Testing
@testable import KeyboardControlFeature

@Test func clampsInitialAndChangedValues() {
    #expect(Level(percent: -1).percent == 0)
    #expect(Level(percent: 101).percent == 100)
    var level = Level(percent: 98)
    level.nudge(6)
    #expect(level.percent == 100)
    level.set(-50)
    #expect(level.percent == 0)
}

@Test func nudgingUnmutes() {
    var level = Level(percent: 50, isMuted: true)
    level.nudge(Level.defaultStep)
    #expect(level == Level(percent: 56, isMuted: false))
}

@Test func settingUnmutes() {
    var level = Level(percent: 50, isMuted: true)
    level.set(40)
    #expect(level == Level(percent: 40, isMuted: false))
}

@Test func mutePreservesLevelAndMakesGainZero() {
    var level = Level(percent: 50)
    #expect(abs(level.gain - 0.25) < 0.0001)
    level.toggleMute()
    #expect(level.percent == 50)
    #expect(level.gain == 0)
    level.toggleMute()
    #expect(abs(level.gain - 0.25) < 0.0001)
}
