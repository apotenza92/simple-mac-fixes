import Foundation
import Testing
@testable import KeyboardControlFeature

@Test func softwareBrightnessSurvivesReconnectionAndControllerRecreation() {
    let suite = "KeyControlBrightnessTest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = SoftwareBrightnessMemory.key(vendor: 7789, model: 23381, serial: 16843009)
    SoftwareBrightnessMemory(defaults: defaults).remember(42, for: key)
    // No transient CG display ID participates in this lookup.
    let recreated = SoftwareBrightnessMemory(defaults: UserDefaults(suiteName: suite)!)
    #expect(recreated.level(for: key) == 42)
    #expect(recreated.level(for: SoftwareBrightnessMemory.key(vendor: 7789, model: 23381, serial: 99)) == nil)
    recreated.remember(100, for: key)
    #expect(recreated.level(for: key) == 100)
}

@Test func softwareBrightnessDoesNotRememberUnidentifiedMonitors() {
    let suite = "KeyControlBrightnessTest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = SoftwareBrightnessMemory(defaults: defaults)
    let key = SoftwareBrightnessMemory.key(vendor: 7789, model: 23381, serial: 0)
    #expect(key == nil)
    memory.remember(20, for: key)
    #expect(memory.level(for: key) == nil)
    #expect(defaults.dictionary(forKey: "softwareBrightnessByDisplay") == nil)
}
