import Foundation
import Testing
@testable import KeyboardControlFeature

@Test func linkedBrightnessSnapsToOneLevel() {
    #expect(DDCController.linkedLevels([1: 40, 2: 70], source: 1, value: 50, linked: true) == [1: 50, 2: 50])
}
@Test func unlinkedBrightnessOnlyChangesSource() {
    #expect(DDCController.linkedLevels([1: 40, 2: 70], source: 2, value: 60, linked: false) == [2: 60])
}
@Test func linkedBrightnessClampsAndIgnoresMissingSource() {
    #expect(DDCController.linkedLevels([1: 40, 2: 95], source: 1, value: 60, linked: true) == [1: 60, 2: 60])
    #expect(DDCController.linkedLevels([1: 40], source: 2, value: 60, linked: true).isEmpty)
}

@Test func brightnessMasterUsesMainDisplayNotArrayOrder() {
    #expect(DDCController.masterID(available: [3, 1], main: 1) == 1)
    #expect(DDCController.masterID(available: [3], main: 1) == 3)
    #expect(DDCController.masterID(available: [], main: 1) == nil)
}

@Test @MainActor func linkingDefaultsOffAndRespectsSavedPreference() {
    let suite = "KeyControlTests.BrightnessLink.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!DDCController(defaults: defaults).isLinked)
    defaults.set(true, forKey: "brightnessLinked")
    #expect(DDCController(defaults: defaults).isLinked)
    defaults.set(false, forKey: "brightnessLinked")
    #expect(!DDCController(defaults: defaults).isLinked)
}
