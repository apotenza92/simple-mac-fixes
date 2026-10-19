import CoreGraphics
import Foundation
import Testing
@testable import SimpleMacFixesCore

@Test func spaceShortcutsComeFromKeyboardShortcutsSettings() {
    let hotKeys: [String: Any] = [
        "79": ["enabled": 1, "value": ["parameters": [65535, 123, 8650752], "type": "standard"]],
        "80": ["enabled": 1, "value": ["parameters": [65535, 123, 8781824], "type": "standard"]],
        "81": ["enabled": 0, "value": ["parameters": [65535, 124, 8650752], "type": "standard"]],
        "118": ["enabled": 1, "value": ["parameters": [65535, 18, 262144], "type": "standard"]],
    ]
    let shortcuts = SpaceShortcuts.parse(hotKeys)
    #expect(Array(shortcuts.prefix(2)) == [
        SpaceShortcut(keyCode: 123, modifiers: .maskControl, action: .left),
        SpaceShortcut(keyCode: 123, modifiers: [.maskControl, .maskShift], action: .left),
    ])
    // A shortcut turned off in System Settings stays off.
    #expect(SpaceShortcuts.match(keyCode: 124, flags: .maskControl, in: shortcuts) == nil)
    // The system's Control-number shortcuts are left to macOS.
    #expect(SpaceShortcuts.match(keyCode: 18, flags: .maskControl, in: shortcuts) == nil)
    // The arrow keys' function-key bit and Caps Lock don't matter; extra modifiers do.
    #expect(SpaceShortcuts.match(keyCode: 123, flags: [.maskControl, .maskSecondaryFn, .maskAlphaShift], in: shortcuts)?.action == .left)
    #expect(SpaceShortcuts.match(keyCode: 123, flags: [.maskControl, .maskCommand], in: shortcuts) == nil)
}

@Test func controlOptionCommandNumbersJumpToDesktopsOneToNine() {
    let shortcuts = SpaceShortcuts.desktopJumps
    let jump: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    #expect(SpaceShortcuts.match(keyCode: 18, flags: jump, in: shortcuts)?.action == .desktop(0))
    #expect(SpaceShortcuts.match(keyCode: 25, flags: jump, in: shortcuts)?.action == .desktop(8))
    #expect(SpaceShortcuts.match(keyCode: 29, flags: jump, in: shortcuts) == nil) // 0 isn't a desktop
    #expect(SpaceShortcuts.match(keyCode: 18, flags: [.maskControl, .maskCommand], in: shortcuts) == nil)
    #expect(SpaceShortcuts.match(keyCode: 48, flags: jump, in: shortcuts)?.action == .next)
    #expect(SpaceShortcuts.match(keyCode: 50, flags: jump, in: shortcuts)?.action == .previous)
}

@Test func nextAndPreviousGoRoundEverySpace() {
    let spaces = [true, false, true] // a full-screen app counts as a space here
    #expect(InstantSpacesFeature.target(for: .next, current: 0, spaces: spaces) == 1)
    #expect(InstantSpacesFeature.target(for: .next, current: 2, spaces: spaces) == 0)
    #expect(InstantSpacesFeature.target(for: .previous, current: 0, spaces: spaces) == 2)
    #expect(InstantSpacesFeature.target(for: .previous, current: 2, spaces: spaces) == 1)
    #expect(InstantSpacesFeature.target(for: .next, current: 0, spaces: [true]) == nil)
}

@Test func unchangedSettingsUseTheSystemDefaults() {
    #expect(SpaceShortcuts.parse(nil).prefix(2).map(\.action) == [.left, .right])
}

@Test func desktopSwitchesNeverRunPastTheEnds() {
    let spaces = [true, false, true, true] // a full-screen app sits second
    #expect(InstantSpacesFeature.target(for: .left, current: 0, spaces: spaces) == nil)
    #expect(InstantSpacesFeature.target(for: .right, current: 3, spaces: spaces) == nil)
    #expect(InstantSpacesFeature.target(for: .right, current: 0, spaces: spaces) == 1)
    // Desktop 2 skips the full-screen app.
    #expect(InstantSpacesFeature.target(for: .desktop(1), current: 0, spaces: spaces) == 2)
    #expect(InstantSpacesFeature.target(for: .desktop(5), current: 0, spaces: spaces) == nil)
}

@Test func instantDockRestoresTheDocksOwnSettings() {
    let suite = "com.apotenza.SimpleMacFixes.tests.\(UUID().uuidString)"
    let dock = "com.apotenza.SimpleMacFixes.tests.dock.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        for (key, _) in InstantDockFeature.instantValues { CFPreferencesSetAppValue(key as CFString, nil, dock as CFString) }
        CFPreferencesAppSynchronize(dock as CFString)
    }
    var restarts = 0
    // Someone had a custom delay and never set the animation speed.
    CFPreferencesSetAppValue("autohide-delay" as CFString, NSNumber(value: 0.5), dock as CFString)
    let feature = InstantDockFeature(defaults: defaults, dockDomain: dock) { restarts += 1 }

    feature.apply()
    #expect(feature.isApplied)
    #expect(CFPreferencesCopyAppValue("autohide-delay" as CFString, dock as CFString) as? NSNumber == 0)
    #expect(CFPreferencesCopyAppValue("autohide-time-modifier" as CFString, dock as CFString) as? NSNumber == 0)
    feature.apply()
    #expect(restarts == 1)

    feature.restore()
    #expect(!feature.isApplied)
    #expect(CFPreferencesCopyAppValue("autohide-delay" as CFString, dock as CFString) as? NSNumber == 0.5)
    #expect(CFPreferencesCopyAppValue("autohide-time-modifier" as CFString, dock as CFString) == nil)
    #expect(restarts == 2)
    feature.restore()
    #expect(restarts == 2)
}

@Test func desktopShortcutsAreTheirOwnSwitch() {
    #expect(!Feature.desktopShortcuts.enabledByDefault)
    #expect(!Feature.instantSpaces.enabledByDefault)
    #expect(!Feature.instantDock.enabledByDefault)
    #expect(Feature.allCases.suffix(3) == [.instantDock, .instantSpaces, .desktopShortcuts])
    // Instant switching alone never catches Control-Option-Command keys.
    let jump: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    #expect(SpaceShortcuts.match(keyCode: 18, flags: jump, in: SpaceShortcuts.parse(nil)) == nil)
}
