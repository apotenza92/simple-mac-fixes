import Testing
@testable import KeyboardControlFeature

private func screen(_ id: UInt32, online: Bool = true, active: Bool = true, mirrored: Bool = false) -> DisplayConnection.Screen {
    .init(id: id, key: "screen-\(id)", builtIn: id == 1, online: online,
          active: active, mirrored: mirrored, vendor: 1, model: 1)
}

@Test func displayDisableRequiresIndependentActiveSurvivor() {
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1), screen(2)]) == nil)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1)]) != nil)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1), screen(2, online: false)]) != nil)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1), screen(2, active: false)]) != nil)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1), screen(2, mirrored: true)]) != nil)
}

@Test func displayDisableRejectsMissingAmbiguousAndMirroredTargets() {
    #expect(DisplayConnection.disableError(target: "missing", screens: [screen(1), screen(2)]) != nil)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1), screen(1), screen(2)]) != nil)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1, mirrored: true), screen(2)]) != nil)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1, online: false, active: false), screen(2)]) != nil)
}

@Test func displayDisableUsesFreshIdentityRatherThanCachedNumericID() {
    let remapped = DisplayConnection.Screen(id: 9, key: "screen-1", builtIn: true,
        online: true, active: true, mirrored: false, vendor: 1, model: 1)
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [remapped, screen(2)]) == nil)
}

@Test func unverifiedOrVirtualDisplayCannotBeTheSafetySurvivor() {
    var virtual = screen(2)
    virtual.physical = false
    #expect(DisplayConnection.disableError(target: "screen-1", screens: [screen(1), virtual]) != nil)
    #expect(DisplayConnection.disableError(target: "screen-2", screens: [screen(1), virtual]) != nil)
}

@Test func identicalDisplaysWithoutSerialsAreRejectedInsteadOfGuessed() {
    let key = DisplayConnection.key(builtIn: false, vendor: 7789, model: 23381, serial: 0)
    let first = DisplayConnection.Screen(id: 2, key: key, builtIn: false, online: true,
        active: true, mirrored: false, vendor: 7789, model: 23381)
    let second = DisplayConnection.Screen(id: 3, key: key, builtIn: false, online: true,
        active: true, mirrored: false, vendor: 7789, model: 23381)
    #expect(DisplayConnection.disableError(target: key, screens: [screen(1), first, second]) != nil)
}

@Test func builtInRecoveryDoesNotDependOnOptionalSerialMetadata() {
    #expect(DisplayConnection.key(builtIn: true, vendor: 1552, model: 41038, serial: 0)
        == DisplayConnection.key(builtIn: true, vendor: 1552, model: 41038, serial: 4251086178))
}
