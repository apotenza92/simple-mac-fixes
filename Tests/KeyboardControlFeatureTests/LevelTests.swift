import Testing
@testable import KeyboardControlFeature

@Test func clampsInitialAndChangedValues() {
    #expect(Level(percent: -1).percent == 0)
    #expect(Level(percent: 101).percent == 100)
    var level = Level(percent: 98)
    level.step(up: true, fine: false)
    #expect(level.percent == 100)
    level.set(-50)
    #expect(level.percent == 0)
}

@Test func steppingUnmutes() {
    var level = Level(percent: 50, isMuted: true)
    level.step(up: true, fine: false)
    #expect(level == Level(percent: 56.25, isMuted: false))
}

@Test func sixteenPressesCoverTheRangeLikeTheSystem() {
    var level = Level(percent: 0)
    for press in 1...16 {
        level.step(up: true, fine: false)
        #expect(level.percent == Double(press) * 6.25)
    }
    level.step(up: true, fine: false)
    #expect(level.percent == 100)
}

@Test func finePressesMoveAQuarterStep() {
    #expect(Level.stepped(50, up: true, fine: true) == 51.5625)
    #expect(Level.stepped(50, up: false, fine: true) == 48.4375)
}

@Test func stepsSnapOtherLevelsToTheNextMark() {
    #expect(Level.stepped(60, up: true, fine: false) == 62.5)
    #expect(Level.stepped(60, up: false, fine: false) == 56.25)
    // A value read back with rounding error still counts as on its mark.
    #expect(Level.stepped(62.4999, up: true, fine: false) == 68.75)
    #expect(Level.stepped(62.5001, up: false, fine: false) == 56.25)
    #expect(Level.stepped(0, up: false, fine: false) == 0)
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
